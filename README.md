# Auditeur de Délivrabilité Email

Script Bash complet d'audit de délivrabilité email, permettant d'analyser la configuration d'un serveur de messagerie et d'évaluer la probabilité qu'un email atteigne sa destination.

## Description

Cet outil effectue une analyse approfondie des facteurs qui influencent la délivrabilité des emails : authentification DNS (SPF, DKIM, DMARC), reverse DNS, serveurs MX, listes noires DNSBL, sécurité TLS, structure du contenu MIME et en-têtes email. Il génère un rapport détaillé avec un score final calculé via une fonction logistique.

## Fonctionnalites

- **Verification SPF** : Analyse complete des enregistrements SPF avec support des inclusions, redirections et mecanismes complexes
- **Verification DKIM** : Detection et validation des signatures DKIM dans les emails reels
- **Verification DMARC** : Analyse de la politique DMARC et evaluation de sa severite
- **Reverse DNS (PTR)** : Verification du FCrDNS (Forward-Confirmed reverse DNS)
- **Serveurs MX** : Evaluation de la redondance et de la configuration des serveurs de messagerie
- **Listes noires DNSBL** : Verification sur 11 bases de donnees de reputation IP
- **Analyse TLS/STARTTLS** : Test de la securite des connexions SMTP sur les ports 25, 587 et 465
- **Analyse du contenu MIME** : Evaluation de la structure texte/HTML, ratio, images et URLs
- **Analyse des en-tetes** : Verification des en-tetes essentiels (List-Unsubscribe, Message-ID, Date)
- **Test de connectivite** : Verification de la disponibilite du serveur mail distant
- **Rapport JSON** : Generation d'un rapport structure avec recommandations personnalisees
- **Score logistique** : Calcul du score final via une courbe sigmoide pour une evaluation realiste

## Dependances

### Obligatoires

| Outil | Package Debian/Ubuntu | Package RHEL/CentOS | Package macOS |
|-------|----------------------|---------------------|---------------|
| dig | dnsutils | bind-utils | bind |
| bc | bc | bc | bc |
| openssl | openssl | openssl | openssl |
| nc (netcat) | netcat-openbsd | nc | netcat |
| ping | iputils-ping | iputils | inetutils-ping |

### Optionnels

| Outil | Fonction | Package |
|-------|----------|---------|
| jq | Formatage du rapport JSON | jq |
| swaks | Generation d'emails de test | swaks |
| curl | Tests supplementaires | curl |
| timeout | Gestion des delais d'attente | coreutils |
| python3 | Fonctionnalites avancees | python3 |

### Installation rapide

**Debian / Ubuntu :**

```bash
sudo apt-get update
sudo apt-get install -y dnsutils bc openssl netcat-openbsd iputils-ping jq swaks curl
```

**RHEL / CentOS / AlmaLinux :**

```bash
sudo yum install -y bind-utils bc openssl nc iputils jq swaks curl
```

**macOS (avec Homebrew) :**

```bash
brew install bind bc openssl netcat iputils jq swaks curl
```

## Utilisation

### Syntaxe

```bash
./email_deliverability_audit.sh [OPTIONS]
```

### Options

| Option | Longue | Description | Valeur par defaut |
|--------|--------|-------------|-------------------|
| -d | --domain | Domaine a tester | lombard-web-services.com |
| -s | --sender | Adresse de l'expediteur | contact@DOMAIN |
| -i | --ip | Adresse IP du serveur d'envoi | 5.135.155.185 |
| -m | --mail-server | Nom d'hote du serveur mail | mail.DOMAIN |
| -f | --file | Chemin vers un fichier email (.eml) | Aucun |
| -o | --output | Nom du fichier JSON de sortie | delivrabilite_audit_DATE.json |
| -t | --timeout | Delai d'attente des requetes (secondes) | 10 |
| -h | --help | Afficher l'aide | - |

### Exemples d'utilisation

**Audit DNS uniquement (sans email) :**

```bash
./email_deliverability_audit.sh -d mon-domaine.com -i 203.0.113.1
```

**Audit complet avec un email reel :**

```bash
./email_deliverability_audit.sh -d mon-domaine.com -i 203.0.113.1 -f /chemin/vers/email.eml
```

**Audit avec serveur mail personnalise :**

```bash
./email_deliverability_audit.sh -d mon-domaine.com -i 203.0.113.1 -m smtp.mon-domaine.com -f email.eml
```

**Generer un email de test avec swaks :**

```bash
swaks --to test@exemple.com --from contact@mon-domaine.com --server smtp.mon-domaine.com --header "Subject: Test d'audit" --body "Email de test pour l'audit de delivrabilite" --quit-after DATA > test.eml
```

## Methodologie de scoring

Le script attribue un score sur 10 points a chaque categorie d'audit, puis calcule un score final via une fonction logistique (courbe sigmoide) pour obtenir une evaluation realiste et non lineaire.

### Categories evaluees

| Categorie | Points max | Critere principal |
|-----------|------------|-------------------|
| SPF | 10 | IP autorisee et politique stricte (-all) |
| DKIM | 10 | Signature valide avec cle 2048 bits |
| DMARC | 10 | Politique p=reject ou p=quarantine |
| Reverse DNS | 10 | FCrDNS valide (PTR vers A vers IP) |
| MX | 10 | Redondance (3+ serveurs = score parfait) |
| Blacklists | 10 | Absence de listage sur les DNSBL |
| Contenu MIME | 10 | Ratio texte/HTML equilibre, structure multipart |
| En-tetes | 10 | Presence de List-Unsubscribe, Message-ID, Date |
| TLS | 10 | Support de TLS 1.2 ou 1.3 avec certificat valide |
| Connectivite | 10 | Ports SMTP ouverts et banniere repondue |

### Interpretation du score final

| Score | Evaluation | Recommandation |
|-------|------------|----------------|
| 8.5 - 10 | Excellent | Configuration optimale, delivrabilite maximale |
| 7.0 - 8.4 | Bon | Configuration solide, quelques optimisations possibles |
| 5.0 - 6.9 | Moyen | Ameliorations recommandees, risque de filtrage |
| 3.0 - 4.9 | Faible | Problemes importants, fort risque de spam |
| 0.0 - 2.9 | Critique | Configuration a revoir entierement |

## Structure du rapport JSON

Le fichier JSON genere contient les sections suivantes :

- **metadata** : Informations sur le domaine teste, la date et la version du script
- **scores** : Score total, score maximal possible, pourcentage et score logistique final
- **details** : Resultats detailles par categorie (score, statut, description)
- **summary.recommendations** : Liste des actions correctives priorisees

## Verification complementaire de la delivrabilite

Pour une analyse complete de la delivrabilite, il est recommande d'utiliser les outils externes suivants en complement de cet audit :

### Mail Tester (mail-tester.com)

Mail-Tester est un service en ligne qui analyse la qualite d'un email en simulant un envoi vers une adresse de test temporaire. Il evalue :

- Le score SpamAssassin
- La presence et la qualite des enregistrements SPF, DKIM et DMARC
- La configuration du reverse DNS
- Le contenu du message (ratio texte/HTML, liens suspects)
- La presence dans les listes noires
- La validite des en-tetes

**Utilisation :**

1. Rendez-vous sur https://www.mail-tester.com
2. Copiez l'adresse email temporaire fournie
3. Envoyez un email depuis votre serveur vers cette adresse
4. Consultez le rapport detaille (note sur 10)

**Avantage :** Evaluation en conditions reelles d'envoi, avec analyse du contenu par des filtres anti-spam.

### Google Postmaster Tools (postmaster.google.com)

Postmaster Tools de Google fournit des statistiques detaillees sur la delivrabilite vers Gmail et les services Google Workspace. Il permet de :

- Consulter le taux de spam signale par les utilisateurs Gmail
- Analyser la reputation de l'adresse IP d'envoi
- Verifier le taux d'erreurs de livraison (bounces)
- Observer les taux d'authentification (SPF, DKIM, DMARC)
- Identifier les problemes de delivrabilite specifiques a Gmail

**Prerequis :**

- Posseder un domaine valide
- Avoir configure les enregistrements DNS du domaine
- Disposer d'un compte Google

**Configuration :**

1. Connectez-vous a https://postmaster.google.com
2. Ajoutez votre domaine
3. Validez la propriete du domaine via l'ajout d'un enregistrement TXT DNS ou l'upload d'un fichier HTML
4. Attendez l'apparition des donnees (generalement 24 a 72 heures apres le premier envoi vers Gmail)

**Avantage :** Donnees directes des serveurs de reception de Google, essentielles pour tout envoi vers des adresses Gmail.

## Verification de la legalite des adresses email

La verification de la legalite et de la validite des adresses email est une etape cruciale avant tout envoi de campagne. Voici les meilleures pratiques :

### Syntaxe et format

- Verifier que l'adresse respecte le format standard (utilisateur@domaine.extension)
- S'assurer de l'absence de caracteres interdits ou mal places
- Verifier la longueur maximale autorisee (254 caracteres au total, 64 pour la partie locale)

### Verification du domaine

- Confirmer que le domaine possede des enregistrements MX valides
- Verifier que le domaine n'est pas un domaine jetable (disposable)
- S'assurer que le domaine n'est pas enregistre comme spammeur

### Verification SMTP (sans envoi)

- Effectuer une verification de la boite via le protocole SMTP (RCPT TO)
- Cette methode permet de valider l'existence de l'adresse sans envoyer d'email
- Attention : certains serveurs retournent toujours un code 250 pour eviter le harvesting

### Outils recommandes

| Outil | Type | Description |
|-------|------|-------------|
| mail-tester.com | En ligne | Test complet d'un email envoye |
| postmaster.google.com | En ligne | Statistiques Gmail et reputation IP |
| verifier.email | En ligne | Verification SMTP en temps reel |
| verify-email.org | En ligne | Validation syntaxique et SMTP |
| email-validator.net | En ligne | Verification multi-criteres |
| MX Toolbox (mxtoolbox.com) | En ligne | Suite d'outils DNS et SMTP |

### Conformite reglementaire

- **RGPD (Europe)** : Assurez-vous d'avoir obtenu le consentement explicite des destinataires. Chaque adresse doit etre collectee legalement avec preuve du consentement.
- **CAN-SPAM (Etats-Unis)** : Incluez une adresse postale valide et un mecanisme de desabonnement fonctionnel.
- **Loi Sapin 2 (France)** : Interdiction du demarchage telephonique non sollicite ; s'applique egalement aux communications electroniques dans certains contextes.
- **PECD (Privacy and Electronic Communications Directive)** : Interdiction de l'envoi d'emails commerciaux non sollicites sans consentement prealable.

## Notes importantes

- L'audit sans fichier email (-f) limite les tests DKIM, contenu MIME et en-tetes. Il est fortement recommande de fournir un email reel pour un audit complet.
- Le script detecte automatiquement les dependances manquantes et propose les commandes d'installation adaptees a votre systeme d'exploitation.
- Le mode simplifie de calcul est active automatiquement si `bc` ne supporte pas les fonctions mathematiques avancees.
- Les tests de blacklists peuvent etre refuses par certains serveurs DNSBL en cas de trop nombreuses requetes depuis la meme IP.

## Auteur

**Thibaut LOMBARD**

- Version : 4.1
- Support serveur distant et verification des dependances

## Licence

Ce script est fourni tel quel, sans garantie d'aucune sorte. L'utilisateur est responsable de son utilisation conforme aux lois et reglementations en vigueur dans son pays.
