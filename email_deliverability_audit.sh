#!/bin/bash

# ============================================================================ #
# Script: email_deliverability_audit.sh
# Description: Audit de délivrabilité email - Version complète avec tests distants
# Auteur: Thibaut LOMBARD
# Version: 4.1 - Support serveur distant et vérification des dépendances
# ============================================================================ #

set -euo pipefail

# ============================================================================ #
# Configuration par défaut
# ============================================================================ #
DEFAULT_DOMAIN="website.tld"
DEFAULT_SENDER="contact@${DEFAULT_DOMAIN}"
DEFAULT_SENDER_IP="12.34.56.78"
DEFAULT_MAIL_SERVER="mail.${DEFAULT_DOMAIN}"
DEFAULT_TEST_EMAIL="test@example.com"
DEFAULT_EMAIL_FILE=""
DEFAULT_TIMEOUT=10

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Variables globales
DOMAIN="$DEFAULT_DOMAIN"
SENDER="$DEFAULT_SENDER"
SENDER_IP="$DEFAULT_SENDER_IP"
MAIL_SERVER="$DEFAULT_MAIL_SERVER"
TEST_EMAIL="$DEFAULT_TEST_EMAIL"
EMAIL_FILE="$DEFAULT_EMAIL_FILE"
TIMEOUT="$DEFAULT_TIMEOUT"
JSON_OUTPUT="deliverability_audit_$(date +%Y%m%d_%H%M%S).json"
TEMP_DIR="/tmp/email_audit_$$"

# Scores
declare -A SCORES
declare -A MAX_SCORES
declare -A STATUS
declare -A DETAILS
TOTAL_SCORE=0
TOTAL_MAX=0
PERCENTAGE=0
FINAL_SCORE=0

# ============================================================================ #
# VÉRIFICATION DES DÉPENDANCES (AVEC INSTALLATION)
# ============================================================================ #

check_dependencies() {
    print_section "VÉRIFICATION DES DÉPENDANCES"
    
    local missing=()
    local installable=()
    local optional_missing=()
    
    # Dépendances obligatoires
    local required_cmds=("dig" "bc" "openssl" "nc" "ping")
    local optional_cmds=("jq" "swaks" "curl" "timeout" "python3")
    
    echo -e "${BLUE}🔍 Vérification des outils nécessaires...${NC}"
    
    # Vérifier les commandes obligatoires
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
            case "$cmd" in
                dig) installable+=("dnsutils" "bind-utils" "bind") ;;
                bc) installable+=("bc" "bc" "bc") ;;
                openssl) installable+=("openssl" "openssl" "openssl") ;;
                nc) installable+=("netcat-openbsd" "nc" "netcat") ;;
                ping) installable+=("iputils-ping" "iputils" "inetutils-ping") ;;
            esac
        fi
    done
    
    # Vérifier les commandes optionnelles
    for cmd in "${optional_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            optional_missing+=("$cmd")
        fi
    done
    
    # Afficher les résultats
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Toutes les dépendances obligatoires sont installées${NC}"
    else
        echo -e "${RED}❌ Dépendances manquantes : ${missing[*]}${NC}"
        echo ""
        echo -e "${YELLOW}📦 Installation automatique possible :${NC}"
        
        # Détection de l'OS
        if [[ -f /etc/debian_version ]]; then
            echo -e "   ${CYAN}Debian/Ubuntu :${NC} sudo apt-get update && sudo apt-get install -y ${installable[*]}"
            echo -e "   ${CYAN}Optionnel :${NC} sudo apt-get install -y jq swaks curl python3"
        elif [[ -f /etc/redhat-release ]]; then
            echo -e "   ${CYAN}RHEL/CentOS :${NC} sudo yum install -y ${installable[*]}"
            echo -e "   ${CYAN}Optionnel :${NC} sudo yum install -y jq swaks curl python3"
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            echo -e "   ${CYAN}macOS :${NC} brew install ${installable[*]}"
            echo -e "   ${CYAN}Optionnel :${NC} brew install jq swaks curl python3"
        fi
        
        echo ""
        read -p "Voulez-vous continuer avec les dépendances disponibles ? (o/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[OoYy]$ ]]; then
            echo -e "${RED}❌ Audit annulé - Installez les dépendances requises${NC}"
            exit 1
        fi
    fi
    
    # Afficher les outils optionnels manquants
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}⚠️ Outils optionnels manquants : ${optional_missing[*]}${NC}"
        echo -e "   ${YELLOW}💡 Ces outils améliorent les fonctionnalités mais ne sont pas obligatoires${NC}"
        
        # Vérifier spécifiquement jq pour le JSON
        if [[ " ${optional_missing[*]} " =~ " jq " ]]; then
            echo -e "   ${YELLOW}⚠️ jq absent - Le rapport JSON sera généré en format brut${NC}"
        fi
    fi
    
    echo ""
    
    # Vérifier la version de bc (nécessite -l pour les exponentielles)
    if command -v bc &> /dev/null; then
        if ! echo "e(1)" | bc -l &> /dev/null; then
            echo -e "${YELLOW}⚠️ bc ne supporte pas les fonctions mathématiques (-l)${NC}"
            echo -e "   ${YELLOW}💡 Installez bc avec support des mathématiques :${NC}"
            echo -e "   ${CYAN}Debian/Ubuntu :${NC} sudo apt-get install -y bc"
            echo -e "   ${CYAN}RHEL/CentOS :${NC} sudo yum install -y bc"
            echo ""
            read -p "Continuer avec des calculs simplifiés ? (o/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[OoYy]$ ]]; then
                exit 1
            fi
            BC_SIMPLE_MODE=true
        else
            BC_SIMPLE_MODE=false
        fi
    fi
    
    # Vérifier la connectivité réseau de base
    if command -v ping &> /dev/null; then
        echo -e "${BLUE}🌐 Vérification de la connectivité réseau...${NC}"
        if ping -c 1 -W 2 8.8.8.8 &> /dev/null || ping -c 1 -W 2 1.1.1.1 &> /dev/null; then
            echo -e "${GREEN}✅ Connectivité internet OK${NC}"
        else
            echo -e "${YELLOW}⚠️ Pas de connectivité internet (les tests DNS pourraient échouer)${NC}"
        fi
        echo ""
    fi
}

# ============================================================================ #
# FONCTIONS D'AFFICHAGE
# ============================================================================ #

print_header() {
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    📧 EMAIL DELIVERABILITY AUDITOR v4.1                        ║${NC}"
    echo -e "${BLUE}║    Audit complet de délivrabilité email - Serveur distant     ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}📋 $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠️ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# ============================================================================ #
# FONCTIONS DE TEST SERVEUR DISTANT
# ============================================================================ #

test_server_connectivity() {
    print_section "TEST DE CONNECTIVITÉ SERVEUR"
    
    echo -e "${BLUE}🔍 Test de connexion au serveur mail distant : $MAIL_SERVER${NC}"
    echo ""
    
    local connectivity_score=0
    local max_connectivity=10
    
    # 1. Test DNS
    echo -e "${BLUE}1. Résolution DNS...${NC}"
    SERVER_IP=$(dig +short "$MAIL_SERVER" 2>/dev/null | head -1)
    if [[ -n "$SERVER_IP" ]]; then
        print_success "Résolution DNS réussie : $SERVER_IP"
        connectivity_score=$((connectivity_score + 2))
    else
        print_error "Impossible de résoudre $MAIL_SERVER"
    fi
    echo ""
    
    # 2. Test ICMP (ping)
    echo -e "${BLUE}2. Test ICMP (ping)...${NC}"
    if command -v ping &> /dev/null; then
        if ping -c 1 -W 3 "$MAIL_SERVER" &> /dev/null; then
            print_success "Ping réussi"
            connectivity_score=$((connectivity_score + 2))
        else
            print_warning "Ping échoué (peut-être bloqué par le pare-feu)"
        fi
    else
        print_warning "ping non disponible"
    fi
    echo ""
    
    # 3. Test SMTP ports
    echo -e "${BLUE}3. Test des ports SMTP...${NC}"
    local ports=("25" "587" "465" "2525")
    local open_ports=()
    
    for port in "${ports[@]}"; do
        if command -v nc &> /dev/null; then
            if timeout 3 nc -zv "$MAIL_SERVER" "$port" 2>&1 | grep -q "succeeded\|Connected" 2>/dev/null; then
                print_success "Port $port ouvert"
                open_ports+=("$port")
                connectivity_score=$((connectivity_score + 1))
            else
                echo -e "${YELLOW}⚠️ Port $port fermé${NC}"
            fi
        else
            print_warning "nc non disponible"
            break
        fi
    done
    echo ""
    
    # 4. Test SMTP Banner
    echo -e "${BLUE}4. Test SMTP Banner...${NC}"
    if [[ ${#open_ports[@]} -gt 0 ]]; then
        local test_port="${open_ports[0]}"
        if command -v nc &> /dev/null; then
            SMTP_BANNER=$(timeout 3 nc "$MAIL_SERVER" "$test_port" 2>&1 | head -1)
            if [[ -n "$SMTP_BANNER" && "$SMTP_BANNER" =~ ^220 ]]; then
                print_success "SMTP Banner reçu : $SMTP_BANNER"
                connectivity_score=$((connectivity_score + 3))
            else
                print_error "Pas de SMTP Banner valide"
            fi
        fi
    else
        print_error "Aucun port SMTP ouvert"
    fi
    echo ""
    
    # Score de connectivité
    SCORES["connectivity"]=$connectivity_score
    MAX_SCORES["connectivity"]=$max_connectivity
    STATUS["connectivity"]="TESTED"
    DETAILS["connectivity"]="Ports ouverts : ${open_ports[*]:-aucun}"
    
    echo -e "${BLUE}📊 Score connectivité: ${SCORES["connectivity"]}/${MAX_SCORES["connectivity"]}${NC}"
    echo ""
}

# ============================================================================ #
# FONCTIONS DE VÉRIFICATION DNS
# ============================================================================ #

ip_to_num() {
    local ip="$1"
    local IFS=.
    local parts=($ip)
    
    if [[ ${#parts[@]} -ne 4 ]]; then
        echo ""
        return 1
    fi
    
    echo $(( (${parts[0]} << 24) + (${parts[1]} << 16) + (${parts[2]} << 8) + ${parts[3]} ))
}

ip_in_cidr() {
    local ip="$1"
    local cidr="$2"
    
    local network="${cidr%/*}"
    local mask="${cidr#*/}"
    
    if [[ -z "$mask" ]]; then
        mask="32"
    fi
    
    local ip_num=$(ip_to_num "$ip")
    local net_num=$(ip_to_num "$network")
    
    if [[ -z "$ip_num" || -z "$net_num" ]]; then
        return 1
    fi
    
    local mask_num=$((0xffffffff << (32 - mask) & 0xffffffff))
    local ip_net=$((ip_num & mask_num))
    local net_net=$((net_num & mask_num))
    
    [[ $ip_net -eq $net_net ]]
}

# ============================================================================ #
# SPF COMPLET
# ============================================================================ #

check_spf() {
    print_section "AUTHENTIFICATION SPF"
    
    SCORES["spf"]=0
    MAX_SCORES["spf"]=10
    DETAILS["spf"]=""
    
    echo -e "${BLUE}🔍 Résolution SPF pour $DOMAIN...${NC}"
    SPF_RECORD=$(dig +short TXT "$DOMAIN" | grep -i "v=spf1" | head -1)
    
    if [[ -z "$SPF_RECORD" ]]; then
        print_error "Aucun enregistrement SPF"
        STATUS["spf"]="FAIL"
        DETAILS["spf"]="Record SPF absent"
        echo -e "${BLUE}📊 Score SPF: ${SCORES["spf"]}/${MAX_SCORES["spf"]}${NC}"
        echo ""
        return
    fi
    
    print_success "SPF record trouvé"
    echo -e "   $SPF_RECORD"
    
    # Parser SPF
    ALLOWED_IPS=()
    ALLOWED_NETWORKS=()
    SPF_RESULT="neutral"
    
    parse_spf() {
        local spf="$1"
        local depth="$2"
        
        if [[ $depth -gt 10 ]]; then
            print_warning "Profondeur SPF maximale atteinte"
            return
        fi
        
        # Parser les mécanismes
        local mechs=("ip4:" "ip6:" "a:" "mx:" "include:" "exists:" "ptr" "redirect=")
        
        for mech in "${mechs[@]}"; do
            if echo "$spf" | grep -q "\b${mech}"; then
                local values=$(echo "$spf" | grep -o "\b${mech}[^ ]*" | sed "s/${mech}//")
                
                for val in $values; do
                    case "$mech" in
                        "ip4:"|"ip6:")
                            if [[ "$val" == *"/"* ]]; then
                                ALLOWED_NETWORKS+=("$val")
                            else
                                ALLOWED_IPS+=("$val")
                            fi
                            ;;
                        "a:"|"mx:")
                            local domain_part="${val:-$DOMAIN}"
                            if [[ "$mech" == "a:" ]]; then
                                local ips=$(dig +short "$domain_part" 2>/dev/null)
                            else
                                local ips=$(dig +short MX "$domain_part" 2>/dev/null | awk '{print $2}' | while read -r mx; do
                                    dig +short "$mx" 2>/dev/null
                                done)
                            fi
                            for ip in $ips; do
                                [[ -n "$ip" ]] && ALLOWED_IPS+=("$ip")
                            done
                            ;;
                        "include:")
                            echo -e "   📎 Inclusion: $val"
                            local included=$(dig +short TXT "$val" 2>/dev/null | grep -i "v=spf1" | head -1)
                            [[ -n "$included" ]] && parse_spf "$included" $((depth + 1))
                            ;;
                        "ptr")
                            echo -e "   ℹ️ Mécanisme PTR détecté"
                            ;;
                        "exists:")
                            echo -e "   ℹ️ Mécanisme EXISTS détecté"
                            ;;
                        "redirect=")
                            echo -e "   🔀 Redirection SPF: $val"
                            local redirected=$(dig +short TXT "$val" 2>/dev/null | grep -i "v=spf1" | head -1)
                            [[ -n "$redirected" ]] && parse_spf "$redirected" $((depth + 1))
                            ;;
                    esac
                done
            fi
        done
        
        # Vérifier les qualifiers
        if echo "$spf" | grep -q "\-all"; then
            SPF_RESULT="fail"
        elif echo "$spf" | grep -q "\~all"; then
            SPF_RESULT="softfail"
        elif echo "$spf" | grep -q "\?all"; then
            SPF_RESULT="neutral"
        fi
    }
    
    parse_spf "$SPF_RECORD" 0
    
    # Vérification IP
    IP_AUTHORIZED=false
    for allowed_ip in "${ALLOWED_IPS[@]}"; do
        if [[ "$allowed_ip" == "$SENDER_IP" ]]; then
            IP_AUTHORIZED=true
            break
        fi
    done
    
    if [[ "$IP_AUTHORIZED" == "false" ]]; then
        for network in "${ALLOWED_NETWORKS[@]}"; do
            if ip_in_cidr "$SENDER_IP" "$network"; then
                IP_AUTHORIZED=true
                break
            fi
        done
    fi
    
    # Score
    if [[ "$IP_AUTHORIZED" == "true" ]]; then
        print_success "IP $SENDER_IP autorisée"
        case "$SPF_RESULT" in
            "fail") SCORES["spf"]=10; print_success "Politique stricte (-all)" ;;
            "softfail") SCORES["spf"]=8; print_warning "Politique douce (~all)" ;;
            "neutral") SCORES["spf"]=6; print_warning "Politique neutre (?all)" ;;
            *) SCORES["spf"]=7 ;;
        esac
        STATUS["spf"]="PASS"
        DETAILS["spf"]="IP autorisée - Politique: $SPF_RESULT"
    else
        print_error "IP $SENDER_IP non autorisée"
        SCORES["spf"]=0
        STATUS["spf"]="FAIL"
        DETAILS["spf"]="IP non autorisée"
    fi
    
    echo -e "${BLUE}📊 Score SPF: ${SCORES["spf"]}/${MAX_SCORES["spf"]}${NC}"
    echo ""
}

# ============================================================================ #
# DKIM
# ============================================================================ #

check_dkim() {
    print_section "AUTHENTIFICATION DKIM"
    
    SCORES["dkim"]=0
    MAX_SCORES["dkim"]=10
    DETAILS["dkim"]=""
    
    if [[ -z "$EMAIL_FILE" || ! -f "$EMAIL_FILE" ]]; then
        print_warning "Impossible de vérifier DKIM sans email réel"
        echo -e "💡 Utilisez -f pour fournir un email signé"
        echo -e "💡 Ou envoyez un email test avec: swaks --to test@exemple.com --from $SENDER --server $MAIL_SERVER"
        SCORES["dkim"]=0
        STATUS["dkim"]="UNKNOWN"
        DETAILS["dkim"]="Nécessite un email"
        echo -e "${BLUE}📊 Score DKIM: ${SCORES["dkim"]}/${MAX_SCORES["dkim"]}${NC}"
        echo ""
        return
    fi
    
    echo -e "🔍 Analyse de l'email pour détecter la signature DKIM..."
    
    DKIM_HEADER=$(grep -i "^DKIM-Signature:" "$EMAIL_FILE" | head -1)
    
    if [[ -z "$DKIM_HEADER" ]]; then
        print_error "Aucune signature DKIM trouvée"
        SCORES["dkim"]=0
        STATUS["dkim"]="FAIL"
        DETAILS["dkim"]="Pas de signature"
        echo -e "${BLUE}📊 Score DKIM: ${SCORES["dkim"]}/${MAX_SCORES["dkim"]}${NC}"
        echo ""
        return
    fi
    
    print_success "Signature DKIM trouvée"
    
    SELECTOR=$(echo "$DKIM_HEADER" | grep -o "s=[^;]*" | cut -d= -f2 | tr -d ' ')
    DOMAIN_SIGNED=$(echo "$DKIM_HEADER" | grep -o "d=[^;]*" | cut -d= -f2 | tr -d ' ')
    ALGORITHM=$(echo "$DKIM_HEADER" | grep -o "a=[^;]*" | cut -d= -f2 | tr -d ' ')
    
    echo -e "   Sélecteur: $SELECTOR"
    echo -e "   Domaine: $DOMAIN_SIGNED"
    echo -e "   Algorithme: $ALGORITHM"
    
    DKIM_RECORD=$(dig +short TXT "${SELECTOR}._domainkey.${DOMAIN_SIGNED}" 2>/dev/null)
    
    if [[ -z "$DKIM_RECORD" ]]; then
        print_error "Record DKIM introuvable"
        SCORES["dkim"]=0
        STATUS["dkim"]="FAIL"
        DETAILS["dkim"]="Record DNS absent"
        echo -e "${BLUE}📊 Score DKIM: ${SCORES["dkim"]}/${MAX_SCORES["dkim"]}${NC}"
        echo ""
        return
    fi
    
    print_success "Record DKIM trouvé dans DNS"
    echo -e "   $DKIM_RECORD"
    
    SCORE=7
    if echo "$DKIM_RECORD" | grep -q "v=DKIM1"; then
        print_success "Version correcte"
        SCORE=$((SCORE + 1))
    fi
    
    KEY_PART=$(echo "$DKIM_RECORD" | grep -o "p=[A-Za-z0-9+/=]*" | cut -d= -f2)
    if [[ -n "$KEY_PART" ]]; then
        KEY_LEN=$(echo -n "$KEY_PART" | wc -c)
        if [[ $KEY_LEN -gt 500 ]]; then
            print_success "Clé 2048 bits estimée"
            SCORE=$((SCORE + 2))
        elif [[ $KEY_LEN -gt 300 ]]; then
            print_warning "Clé 1024 bits estimée (acceptable)"
            SCORE=$((SCORE + 1))
        fi
    fi
    
    [[ $SCORE -gt 10 ]] && SCORE=10
    
    SCORES["dkim"]=$SCORE
    STATUS["dkim"]="PASS"
    DETAILS["dkim"]="Signature valide avec sélecteur $SELECTOR"
    
    echo -e "${BLUE}📊 Score DKIM: ${SCORES["dkim"]}/${MAX_SCORES["dkim"]}${NC}"
    echo ""
}

# ============================================================================ #
# DMARC
# ============================================================================ #

check_dmarc() {
    print_section "POLITIQUE DMARC"
    
    SCORES["dmarc"]=0
    MAX_SCORES["dmarc"]=10
    DETAILS["dmarc"]=""
    
    echo -e "${BLUE}🔍 Résolution DMARC pour $DOMAIN...${NC}"
    DMARC_RECORD=$(dig +short TXT "_dmarc.$DOMAIN" 2>/dev/null)
    
    if [[ -z "$DMARC_RECORD" ]]; then
        print_error "Aucun enregistrement DMARC"
        STATUS["dmarc"]="FAIL"
        DETAILS["dmarc"]="Record DMARC absent"
        echo -e "${BLUE}📊 Score DMARC: ${SCORES["dmarc"]}/${MAX_SCORES["dmarc"]}${NC}"
        echo ""
        return
    fi
    
    print_success "DMARC record trouvé"
    echo -e "   $DMARC_RECORD"
    
    SCORE=0
    
    if echo "$DMARC_RECORD" | grep -q "p=reject"; then
        print_success "Politique: reject"
        SCORE=8
    elif echo "$DMARC_RECORD" | grep -q "p=quarantine"; then
        print_warning "Politique: quarantine"
        SCORE=6
    elif echo "$DMARC_RECORD" | grep -q "p=none"; then
        print_warning "Politique: none (monitoring)"
        SCORE=3
    fi
    
    if echo "$DMARC_RECORD" | grep -q "sp=reject"; then
        print_success "Sous-domaine: reject"
        SCORE=$((SCORE + 1))
    fi
    
    if echo "$DMARC_RECORD" | grep -q "pct=100"; then
        print_success "Appliqué à 100%"
        SCORE=$((SCORE + 1))
    fi
    
    if echo "$DMARC_RECORD" | grep -q "rua="; then
        print_success "Rapports configurés"
        SCORE=$((SCORE + 0.5))
    fi
    
    SCORE=$(printf "%.0f" "$SCORE")
    [[ $SCORE -gt 10 ]] && SCORE=10
    
    SCORES["dmarc"]=$SCORE
    STATUS["dmarc"]="PASS"
    DETAILS["dmarc"]="Politique DMARC configurée"
    
    echo -e "${BLUE}📊 Score DMARC: ${SCORES["dmarc"]}/${MAX_SCORES["dmarc"]}${NC}"
    echo ""
}

# ============================================================================ #
# REVERSE DNS
# ============================================================================ #

check_reverse_dns() {
    print_section "REVERSE DNS (PTR)"
    
    SCORES["rdns"]=0
    MAX_SCORES["rdns"]=10
    DETAILS["rdns"]=""
    
    echo -e "${BLUE}🔍 Résolution PTR pour $SENDER_IP...${NC}"
    REVERSE=$(dig +short -x "$SENDER_IP" 2>/dev/null | head -1)
    
    if [[ -z "$REVERSE" ]]; then
        print_error "Aucun enregistrement PTR"
        STATUS["rdns"]="FAIL"
        DETAILS["rdns"]="PTR absent"
        echo -e "${BLUE}📊 Score RDNS: ${SCORES["rdns"]}/${MAX_SCORES["rdns"]}${NC}"
        echo ""
        return
    fi
    
    print_success "PTR trouvé: $REVERSE"
    
    FORWARD_IP=$(dig +short "$REVERSE" 2>/dev/null | head -1)
    
    if [[ "$FORWARD_IP" == "$SENDER_IP" ]]; then
        print_success "FCrDNS validé (PTR → A → IP)"
        SCORES["rdns"]=10
        STATUS["rdns"]="PASS"
        DETAILS["rdns"]="FCrDNS valide"
    elif [[ -n "$FORWARD_IP" ]]; then
        print_warning "PTR vers $REVERSE mais A vers $FORWARD_IP"
        SCORES["rdns"]=5
        STATUS["rdns"]="PARTIAL"
        DETAILS["rdns"]="PTR ne correspond pas à A"
    else
        print_warning "A record absent pour le PTR"
        SCORES["rdns"]=3
        STATUS["rdns"]="PARTIAL"
        DETAILS["rdns"]="A record absent"
    fi
    
    echo -e "${BLUE}📊 Score RDNS: ${SCORES["rdns"]}/${MAX_SCORES["rdns"]}${NC}"
    echo ""
}

# ============================================================================ #
# MX Records
# ============================================================================ #

check_mx_records() {
    print_section "SERVEURS MX"
    
    SCORES["mx"]=0
    MAX_SCORES["mx"]=10
    DETAILS["mx"]=""
    
    echo -e "${BLUE}🔍 Résolution MX pour $DOMAIN...${NC}"
    MX_RECORDS=$(dig +short MX "$DOMAIN" 2>/dev/null | sort -n)
    
    if [[ -z "$MX_RECORDS" ]]; then
        print_error "Aucun enregistrement MX"
        STATUS["mx"]="FAIL"
        DETAILS["mx"]="MX absent"
        echo -e "${BLUE}📊 Score MX: ${SCORES["mx"]}/${MAX_SCORES["mx"]}${NC}"
        echo ""
        return
    fi
    
    print_success "MX records trouvés"
    echo "$MX_RECORDS" | while read -r line; do
        echo -e "   $line"
    done
    
    MX_COUNT=$(echo "$MX_RECORDS" | wc -l)
    
    if [[ $MX_COUNT -ge 3 ]]; then
        print_success "Excellente redondance ($MX_COUNT serveurs)"
        SCORES["mx"]=10
    elif [[ $MX_COUNT -ge 2 ]]; then
        print_success "Bonne redondance ($MX_COUNT serveurs)"
        SCORES["mx"]=8
    else
        print_warning "Un seul serveur MX (pas de redondance)"
        SCORES["mx"]=4
    fi
    
    STATUS["mx"]="PASS"
    DETAILS["mx"]="$MX_COUNT serveurs MX"
    
    echo -e "${BLUE}📊 Score MX: ${SCORES["mx"]}/${MAX_SCORES["mx"]}${NC}"
    echo ""
}

# ============================================================================ #
# BLACKLISTS
# ============================================================================ #

check_blacklists() {
    print_section "BLACKLISTS DNSBL"
    
    SCORES["blacklist"]=0
    MAX_SCORES["blacklist"]=10
    DETAILS["blacklist"]=""
    
    declare -A BLACKLISTS=(
        ["zen.spamhaus.org"]="127.0.0.2 127.0.0.3 127.0.0.4 127.0.0.5 127.0.0.6 127.0.0.7 127.0.0.10 127.0.0.11 127.255.255.254 127.255.255.255"
        ["bl.spamcop.net"]="127.0.0.2"
        ["dnsbl.sorbs.net"]="127.0.0.2 127.0.0.3 127.0.0.4 127.0.0.5 127.0.0.6 127.0.0.7 127.0.0.8 127.0.0.9 127.0.0.10"
        ["cbl.abuseat.org"]="127.0.0.2"
        ["b.barracudacentral.org"]="127.0.0.2"
        ["dnsbl-1.uceprotect.net"]="127.0.0.2"
        ["psbl.surriel.com"]="127.0.0.2"
        ["spam.dnsbl.anonmails.de"]="127.0.0.2"
        ["dnsbl.dronebl.org"]="127.0.0.3 127.0.0.5 127.0.0.6 127.0.0.14"
        ["dnsbl.spfbl.net"]="127.0.0.1 127.0.0.2 127.0.0.3"
        ["rbl.interserver.net"]="127.0.0.2"
    )
    
    LISTED_COUNT=0
    REFUSED_COUNT=0
    TOTAL_CHECKED=0
    REVERSE_IP=$(echo "$SENDER_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
    
    echo -e "${BLUE}🔍 Vérification de $SENDER_IP sur ${#BLACKLISTS[@]} blacklists...${NC}"
    echo ""
    
    for BL in "${!BLACKLISTS[@]}"; do
        QUERY="${REVERSE_IP}.${BL}"
        ((TOTAL_CHECKED++))
        
        RESULT=$(timeout 5 dig +short "$QUERY" 2>/dev/null || echo "TIMEOUT")
        
        if [[ "$RESULT" == "TIMEOUT" ]]; then
            echo -e "${YELLOW}⏳ Timeout sur $BL${NC}"
        elif [[ -z "$RESULT" ]]; then
            echo -e "${GREEN}✅ Non listé sur $BL${NC}"
        elif [[ "$RESULT" == "127.255.255.254" || "$RESULT" == "127.255.255.255" ]]; then
            echo -e "${YELLOW}⚠️ Requête refusée par $BL${NC}"
            ((REFUSED_COUNT++))
        else
            IS_LISTED=false
            for IP_PATTERN in ${BLACKLISTS[$BL]}; do
                if [[ "$RESULT" == "$IP_PATTERN" ]]; then
                    IS_LISTED=true
                    break
                fi
            done
            
            if [[ "$IS_LISTED" == "true" ]]; then
                echo -e "${RED}❌ LISTÉ sur $BL ($RESULT)${NC}"
                ((LISTED_COUNT++))
            else
                echo -e "${YELLOW}⚠️ Résultat inattendu sur $BL: $RESULT${NC}"
            fi
        fi
    done
    echo ""
    
    if [[ $LISTED_COUNT -eq 0 ]]; then
        if [[ $REFUSED_COUNT -gt 0 ]]; then
            print_warning "$REFUSED_COUNT requêtes refusées"
            SCORES["blacklist"]=7
            STATUS["blacklist"]="PARTIAL"
            DETAILS["blacklist"]="$REFUSED_COUNT refusées"
        else
            print_success "IP non listée sur toutes les DNSBL"
            SCORES["blacklist"]=10
            STATUS["blacklist"]="CLEAN"
            DETAILS["blacklist"]="Non listée"
        fi
    else
        print_error "IP listée sur $LISTED_COUNT DNSBL"
        SCORES["blacklist"]=$((10 - LISTED_COUNT * 2))
        [[ ${SCORES["blacklist"]} -lt 0 ]] && SCORES["blacklist"]=0
        STATUS["blacklist"]="LISTED"
        DETAILS["blacklist"]="$LISTED_COUNT listes"
    fi
    
    echo -e "${BLUE}📊 Score Blacklist: ${SCORES["blacklist"]}/${MAX_SCORES["blacklist"]}${NC}"
    echo ""
}

# ============================================================================ #
# ANALYSE MIME
# ============================================================================ #

analyze_email_content() {
    print_section "ANALYSE DU CONTENU"
    
    SCORES["content"]=0
    MAX_SCORES["content"]=10
    DETAILS["content"]=""
    
    if [[ -z "$EMAIL_FILE" || ! -f "$EMAIL_FILE" ]]; then
        print_warning "Aucun email fourni"
        SCORES["content"]=0
        STATUS["content"]="UNKNOWN"
        DETAILS["content"]="Aucun email"
        echo -e "${BLUE}📊 Score Contenu: ${SCORES["content"]}/${MAX_SCORES["content"]}${NC}"
        echo ""
        return
    fi
    
    echo -e "🔍 Analyse MIME de l'email..."
    
    SCORE=0
    BOUNDARY=$(grep -i "^Content-Type: multipart" "$EMAIL_FILE" | head -1 | grep -o "boundary=\"[^\"]*\"" | cut -d'"' -f2)
    
    if [[ -z "$BOUNDARY" ]]; then
        BOUNDARY=$(grep -i "^Content-Type: multipart" "$EMAIL_FILE" | head -1 | grep -o "boundary=[^;]*" | cut -d= -f2 | tr -d ' ')
    fi
    
    if [[ -n "$BOUNDARY" ]]; then
        print_success "Boundary détecté: $BOUNDARY"
        SCORE=$((SCORE + 2))
    else
        print_warning "Pas de structure multipart"
    fi
    
    HAS_HTML=false
    HAS_TEXT=false
    
    if grep -qi "^Content-Type:.*text/html" "$EMAIL_FILE"; then
        HAS_HTML=true
        print_success "Version HTML présente"
        SCORE=$((SCORE + 2))
    fi
    
    if grep -qi "^Content-Type:.*text/plain" "$EMAIL_FILE"; then
        HAS_TEXT=true
        print_success "Version texte présente"
        SCORE=$((SCORE + 2))
    fi
    
    if [[ -n "$BOUNDARY" && "$HAS_HTML" == "true" && "$HAS_TEXT" == "true" ]]; then
        TEXT_PART=$(awk "/Content-Type: text\/plain/,/$BOUNDARY/" "$EMAIL_FILE" | grep -v "Content-Type" | grep -v "Content-Transfer" | wc -c)
        HTML_PART=$(awk "/Content-Type: text\/html/,/$BOUNDARY/" "$EMAIL_FILE" | grep -v "Content-Type" | grep -v "Content-Transfer" | wc -c)
        
        TOTAL=$((TEXT_PART + HTML_PART))
        if [[ $TOTAL -gt 0 ]]; then
            RATIO=$((TEXT_PART * 100 / TOTAL))
            echo -e "📊 Ratio texte/HTML: ${RATIO}%"
            
            if [[ $RATIO -gt 30 ]]; then
                print_success "Bon ratio"
                SCORE=$((SCORE + 2))
            elif [[ $RATIO -gt 10 ]]; then
                print_warning "Ratio moyen"
                SCORE=$((SCORE + 1))
            fi
        fi
    fi
    
    IMG_COUNT=$(grep -io "<img" "$EMAIL_FILE" | wc -l)
    if [[ $IMG_COUNT -gt 0 ]]; then
        echo -e "🖼️ $IMG_COUNT images"
        ALT_COUNT=$(grep -io "alt=" "$EMAIL_FILE" | wc -l)
        if [[ $ALT_COUNT -eq $IMG_COUNT ]]; then
            print_success "Toutes les images ont alt"
            SCORE=$((SCORE + 2))
        fi
    fi
    
    URL_COUNT=$(grep -io "https\?://[^ \"'<>]*" "$EMAIL_FILE" | wc -l)
    if [[ $URL_COUNT -gt 0 ]]; then
        echo -e "🔗 $URL_COUNT URLs"
        SHORT_FOUND=0
        for short in "bit.ly" "tinyurl" "goo.gl" "ow.ly" "buff.ly"; do
            if grep -qi "$short" "$EMAIL_FILE"; then
                SHORT_FOUND=1
                break
            fi
        done
        if [[ $SHORT_FOUND -eq 0 ]]; then
            print_success "Pas d'URLs raccourcies"
            SCORE=$((SCORE + 1))
        fi
    fi
    
    [[ $SCORE -gt 10 ]] && SCORE=10
    
    SCORES["content"]=$SCORE
    STATUS["content"]="ANALYZED"
    DETAILS["content"]="Structure MIME analysée"
    
    echo -e "${BLUE}📊 Score Contenu: ${SCORES["content"]}/${MAX_SCORES["content"]}${NC}"
    echo ""
}

# ============================================================================ #
# HEADERS
# ============================================================================ #

check_headers() {
    print_section "HEADERS EMAIL"
    
    SCORES["headers"]=0
    MAX_SCORES["headers"]=10
    DETAILS["headers"]=""
    
    if [[ -z "$EMAIL_FILE" || ! -f "$EMAIL_FILE" ]]; then
        print_warning "Aucun email fourni"
        SCORES["headers"]=0
        STATUS["headers"]="UNKNOWN"
        DETAILS["headers"]="Aucun email"
        echo -e "${BLUE}📊 Score Headers: ${SCORES["headers"]}/${MAX_SCORES["headers"]}${NC}"
        echo ""
        return
    fi
    
    SCORE=5
    
    if grep -qi "^List-Unsubscribe:" "$EMAIL_FILE"; then
        print_success "List-Unsubscribe présent"
        SCORE=$((SCORE + 2))
    else
        print_warning "Pas de List-Unsubscribe"
    fi
    
    if grep -qi "^Authentication-Results:" "$EMAIL_FILE"; then
        print_success "Authentication-Results présent"
        SCORE=$((SCORE + 2))
    fi
    
    if grep -qi "^Message-ID:" "$EMAIL_FILE"; then
        print_success "Message-ID présent"
        SCORE=$((SCORE + 1))
    fi
    
    if grep -qi "^Date:" "$EMAIL_FILE"; then
        print_success "Date présente"
        SCORE=$((SCORE + 1))
    fi
    
    [[ $SCORE -gt 10 ]] && SCORE=10
    
    SCORES["headers"]=$SCORE
    STATUS["headers"]="ANALYZED"
    DETAILS["headers"]="Headers analysés"
    
    echo -e "${BLUE}📊 Score Headers: ${SCORES["headers"]}/${MAX_SCORES["headers"]}${NC}"
    echo ""
}

# ============================================================================ #
# TLS MULTI-PORTS
# ============================================================================ #

check_tls() {
    print_section "SÉCURITÉ TLS/STARTTLS"
    
    SCORES["tls"]=0
    MAX_SCORES["tls"]=10
    DETAILS["tls"]=""
    
    if ! command -v openssl &> /dev/null; then
        print_warning "openssl non installé"
        SCORES["tls"]=0
        STATUS["tls"]="UNKNOWN"
        DETAILS["tls"]="openssl manquant"
        echo -e "${BLUE}📊 Score TLS: ${SCORES["tls"]}/${MAX_SCORES["tls"]}${NC}"
        echo ""
        return
    fi
    
    PORTS=("25" "587" "465")
    BEST_SCORE=0
    BEST_PORT=""
    
    for port in "${PORTS[@]}"; do
        echo -e "🔐 Test STARTTLS sur $MAIL_SERVER:$port"
        
        if [[ "$port" == "465" ]]; then
            TLS_OUTPUT=$(timeout 5 openssl s_client -connect "$MAIL_SERVER:$port" -servername "$MAIL_SERVER" 2>/dev/null || echo "FAIL")
        else
            TLS_OUTPUT=$(timeout 5 openssl s_client -starttls smtp -connect "$MAIL_SERVER:$port" -servername "$MAIL_SERVER" 2>/dev/null || echo "FAIL")
        fi
        
        if [[ "$TLS_OUTPUT" != "FAIL" ]]; then
            TLS_VERSION=$(echo "$TLS_OUTPUT" | grep -i "Protocol" | head -1 | awk '{print $2}')
            TLS_CIPHER=$(echo "$TLS_OUTPUT" | grep -i "Cipher" | head -1 | awk '{print $2}')
            
            echo -e "   Version: ${TLS_VERSION:-Non détectée}"
            echo -e "   Cipher: ${TLS_CIPHER:-Non détecté}"
            
            PORT_SCORE=0
            case "$TLS_VERSION" in
                *TLSv1.3*)
                    print_success "TLS 1.3"
                    PORT_SCORE=10
                    ;;
                *TLSv1.2*)
                    print_success "TLS 1.2"
                    PORT_SCORE=9
                    ;;
                *TLSv1.1*)
                    print_warning "TLS 1.1 (déprécié)"
                    PORT_SCORE=4
                    ;;
                *TLSv1*)
                    print_error "TLS 1.0"
                    PORT_SCORE=2
                    ;;
                *)
                    print_warning "Version inconnue"
                    PORT_SCORE=5
                    ;;
            esac
            
            if echo "$TLS_OUTPUT" | grep -q "Verify return code: 0"; then
                print_success "Certificat valide"
                PORT_SCORE=$((PORT_SCORE + 1))
            fi
            
            [[ $PORT_SCORE -gt 10 ]] && PORT_SCORE=10
            
            if [[ $PORT_SCORE -gt $BEST_SCORE ]]; then
                BEST_SCORE=$PORT_SCORE
                BEST_PORT="$port"
            fi
        else
            print_warning "TLS non supporté sur port $port"
        fi
        echo ""
    done
    
    if [[ -n "$BEST_PORT" ]]; then
        print_success "Meilleure configuration TLS sur port $BEST_PORT"
        SCORES["tls"]=$BEST_SCORE
        STATUS["tls"]="SECURE"
        DETAILS["tls"]="TLS sur port $BEST_PORT"
    else
        print_error "TLS non supporté sur aucun port"
        SCORES["tls"]=0
        STATUS["tls"]="FAIL"
        DETAILS["tls"]="TLS absent"
    fi
    
    echo -e "${BLUE}📊 Score TLS: ${SCORES["tls"]}/${MAX_SCORES["tls"]}${NC}"
    echo ""
}

# ============================================================================ #
# SCORE LOGISTIQUE
# ============================================================================ #

calculate_logistic() {
    local x="$1"
    local k="$2"
    local midpoint="$3"
    
    if [[ "$BC_SIMPLE_MODE" == "true" ]]; then
        # Mode simplifié
        if (( $(echo "$x >= 0.9" | bc -l) )); then
            echo "10"
        elif (( $(echo "$x >= 0.8" | bc -l) )); then
            echo "9"
        elif (( $(echo "$x >= 0.7" | bc -l) )); then
            echo "8"
        elif (( $(echo "$x >= 0.6" | bc -l) )); then
            echo "7"
        elif (( $(echo "$x >= 0.5" | bc -l) )); then
            echo "6"
        elif (( $(echo "$x >= 0.4" | bc -l) )); then
            echo "5"
        elif (( $(echo "$x >= 0.3" | bc -l) )); then
            echo "4"
        elif (( $(echo "$x >= 0.2" | bc -l) )); then
            echo "3"
        elif (( $(echo "$x >= 0.1" | bc -l) )); then
            echo "2"
        else
            echo "1"
        fi
    else
        # Vraie fonction logistique avec bc -l
        local exp_arg=$(echo "scale=6; -$k * ($x - $midpoint)" | bc -l)
        local exp_val=$(echo "scale=6; e($exp_arg)" | bc -l 2>/dev/null || echo "0")
        local result=$(echo "scale=2; 10 / (1 + $exp_val)" | bc -l 2>/dev/null || echo "5.0")
        printf "%.1f" "$result"
    fi
}

calculate_final_score() {
    print_section "SCORE FINAL"
    
    TOTAL_SCORE=0
    TOTAL_MAX=0
    
    for key in "${!SCORES[@]}"; do
        TOTAL_SCORE=$((TOTAL_SCORE + ${SCORES[$key]}))
        TOTAL_MAX=$((TOTAL_MAX + ${MAX_SCORES[$key]}))
    done
    
    if [[ $TOTAL_MAX -gt 0 ]]; then
        PERCENTAGE=$(echo "scale=2; $TOTAL_SCORE * 100 / $TOTAL_MAX" | bc)
    else
        PERCENTAGE=0
    fi
    
    X_NORMALIZED=$(echo "scale=4; $PERCENTAGE / 100" | bc)
    FINAL_SCORE=$(calculate_logistic "$X_NORMALIZED" 8 0.5)
    
    echo -e "📊 Score total: $TOTAL_SCORE/$TOTAL_MAX"
    echo -e "📊 Pourcentage: ${PERCENTAGE}%"
    echo -e "${GREEN}🎯 Score final (logistique): $FINAL_SCORE/10${NC}"
    
    if (( $(echo "$FINAL_SCORE >= 8.5" | bc -l) )); then
        echo -e "${GREEN}🌟 Excellent - Configuration optimale${NC}"
    elif (( $(echo "$FINAL_SCORE >= 7.0" | bc -l) )); then
        echo -e "${GREEN}✅ Bon - Configuration solide${NC}"
    elif (( $(echo "$FINAL_SCORE >= 5.0" | bc -l) )); then
        echo -e "${YELLOW}⚠️ Moyen - Améliorations recommandées${NC}"
    elif (( $(echo "$FINAL_SCORE >= 3.0" | bc -l) )); then
        echo -e "${RED}❌ Faible - Problèmes importants${NC}"
    else
        echo -e "${RED}🚨 Critique - Configuration à revoir${NC}"
    fi
    
    echo ""
}

# ============================================================================ #
# GÉNÉRATION JSON
# ============================================================================ #

generate_json() {
    print_section "RAPPORT JSON"
    
    cat > "$JSON_OUTPUT" << EOF
{
  "metadata": {
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "version": "4.1",
    "domain_tested": "$DOMAIN",
    "sender": "$SENDER",
    "ip": "$SENDER_IP",
    "mail_server": "$MAIL_SERVER",
    "email_file": "${EMAIL_FILE:-N/A}"
  },
  "scores": {
    "total": $TOTAL_SCORE,
    "max_possible": $TOTAL_MAX,
    "percentage": $PERCENTAGE,
    "final_logistic": $FINAL_SCORE
  },
  "details": {
EOF
    
    local first=true
    for key in "${!SCORES[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$JSON_OUTPUT"
        fi
        echo -n '    "'$key'": {"score": '${SCORES[$key]}', "max": '${MAX_SCORES[$key]}', "status": "'${STATUS[$key]:-UNKNOWN}'", "details": "'${DETAILS[$key]:-Aucun détail}'"}' >> "$JSON_OUTPUT"
    done
    
    echo "" >> "$JSON_OUTPUT"
    echo "  }," >> "$JSON_OUTPUT"
    echo '  "summary": {' >> "$JSON_OUTPUT"
    echo '    "recommendations": [' >> "$JSON_OUTPUT"
    
    local recs=()
    [[ ${SCORES["spf"]:-0} -lt 7 ]] && recs+=('"Configurer SPF avec politique -all"')
    [[ ${SCORES["dkim"]:-0} -lt 7 ]] && recs+=('"Signer les emails avec DKIM (clé 2048 bits)"')
    [[ ${SCORES["dmarc"]:-0} -lt 7 ]] && recs+=('"Mettre en place DMARC p=quarantine ou p=reject"')
    [[ ${SCORES["rdns"]:-0} -lt 7 ]] && recs+=('"Configurer le reverse DNS (PTR)"')
    [[ ${SCORES["blacklist"]:-0} -lt 8 ]] && recs+=('"Vérifier les blacklists"')
    [[ ${SCORES["content"]:-0} -lt 7 ]] && recs+=('"Améliorer le ratio texte/HTML"')
    [[ ${SCORES["headers"]:-0} -lt 7 ]] && recs+=('"Ajouter les headers de désabonnement"')
    [[ ${SCORES["tls"]:-0} -lt 7 ]] && recs+=('"Activer TLS 1.2 ou 1.3"')
    [[ ${SCORES["connectivity"]:-0} -lt 5 ]] && recs+=('"Vérifier la connectivité du serveur mail"')
    
    if [[ ${#recs[@]} -eq 0 ]]; then
        echo '      "Aucune recommandation majeure"' >> "$JSON_OUTPUT"
    else
        for i in "${!recs[@]}"; do
            if [[ $i -eq $((${#recs[@]} - 1)) ]]; then
                echo "      ${recs[$i]}" >> "$JSON_OUTPUT"
            else
                echo "      ${recs[$i]}," >> "$JSON_OUTPUT"
            fi
        done
    fi
    
    echo '    ]' >> "$JSON_OUTPUT"
    echo '  }' >> "$JSON_OUTPUT"
    echo '}' >> "$JSON_OUTPUT"
    
    print_success "Rapport JSON sauvegardé : $JSON_OUTPUT"
    if command -v jq &> /dev/null; then
        echo -e "${BLUE}📋 Aperçu :${NC}"
        jq '.metadata, .scores' "$JSON_OUTPUT" 2>/dev/null || cat "$JSON_OUTPUT" | head -20
    else
        echo -e "${YELLOW}⚠️ jq non installé - affichage brut${NC}"
        head -20 "$JSON_OUTPUT"
    fi
    echo ""
}

# ============================================================================ #
# OPTIONS
# ============================================================================ #

show_help() {
    cat << EOF
${BLUE}EMAIL DELIVERABILITY AUDITOR v4.1${NC}
Usage: $0 [OPTIONS]

${GREEN}Options:${NC}
  -d, --domain DOMAIN        Domaine à tester (défaut: $DEFAULT_DOMAIN)
  -s, --sender EMAIL         Expéditeur (défaut: contact@DOMAIN)
  -i, --ip IP_ADDRESS        IP du serveur (défaut: $DEFAULT_SENDER_IP)
  -m, --mail-server HOST     Serveur mail (défaut: mail.DOMAIN)
  -f, --file EMAIL_FILE      Analyser un email réel (RECOMMANDÉ)
  -o, --output FILE          Fichier JSON de sortie
  -t, --timeout SECONDS      Timeout pour les requêtes (défaut: 10)
  -h, --help                 Afficher cette aide

${YELLOW}Exemples:${NC}
  # Audit DNS uniquement
  $0 -d mon-domaine.com -i 1.2.3.4

  # Audit complet avec email réel
  $0 -d mon-domaine.com -i 1.2.3.4 -f /tmp/email.eml

  # Audit avec serveur mail personnalisé
  $0 -d mon-domaine.com -i 1.2.3.4 -m smtp.mon-domaine.com -f /tmp/email.eml

${BLUE}Pour tester avec un serveur distant:${NC}
  1. Envoyez un email test depuis votre serveur
  2. Sauvegardez l'email source (.eml)
  3. Exécutez l'audit avec -f

${BLUE}Pour générer un email test:${NC}
  swaks --to test@exemple.com --from $SENDER --server $MAIL_SERVER --header "Subject: Test" --body "Test email" --quit-after DATA > test.eml
EOF
    exit 0
}

# Parser les arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -s|--sender)
            SENDER="$2"
            shift 2
            ;;
        -i|--ip)
            SENDER_IP="$2"
            shift 2
            ;;
        -m|--mail-server)
            MAIL_SERVER="$2"
            shift 2
            ;;
        -f|--file)
            EMAIL_FILE="$2"
            shift 2
            ;;
        -o|--output)
            JSON_OUTPUT="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}❌ Option inconnue: $1${NC}"
            echo "Utilisez -h pour l'aide"
            exit 1
            ;;
    esac
done

# Mise à jour des valeurs dérivées
if [[ "$SENDER" == "$DEFAULT_SENDER" && "$DOMAIN" != "$DEFAULT_DOMAIN" ]]; then
    SENDER="contact@${DOMAIN}"
fi
if [[ "$MAIL_SERVER" == "$DEFAULT_MAIL_SERVER" && "$DOMAIN" != "$DEFAULT_DOMAIN" ]]; then
    MAIL_SERVER="mail.${DOMAIN}"
fi

# ============================================================================ #
# MAIN
# ============================================================================ #

main() {
    print_header
    
    echo -e "${YELLOW}📧 Configuration de l'audit :${NC}"
    echo -e "   Domaine : $DOMAIN"
    echo -e "   IP : $SENDER_IP"
    echo -e "   Serveur : $MAIL_SERVER"
    echo -e "   Timeout : ${TIMEOUT}s"
    if [[ -n "$EMAIL_FILE" ]]; then
        echo -e "   Email : $EMAIL_FILE"
    else
        echo -e "   ${YELLOW}⚠️ Audit limité (aucun email fourni)${NC}"
    fi
    echo ""
    
    # Vérification des dépendances
    check_dependencies
    
    # Créer un répertoire temporaire
    mkdir -p "$TEMP_DIR"
    
    # Test de connectivité au serveur distant
    test_server_connectivity
    
    # Exécuter les vérifications
    check_spf
    check_dkim
    check_dmarc
    check_reverse_dns
    check_mx_records
    check_blacklists
    analyze_email_content
    check_headers
    check_tls
    
    # Score final
    calculate_final_score
    
    # Rapport
    generate_json
    
    # Nettoyage
    rm -rf "$TEMP_DIR"
    
    echo -e "${GREEN}✅ Audit terminé !${NC}"
    echo -e "${BLUE}📊 Rapport complet : $JSON_OUTPUT${NC}"
    echo ""
}

# ============================================================================ #
# EXÉCUTION
# ============================================================================ #

main "$@"
