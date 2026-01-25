# Aide S3 Next

Bienvenue dans l'aide de **S3 Next**, votre client S3 performant et sécurisé pour macOS et iOS. Cette application a été conçue pour offrir une gestion fluide de vos données tout en garantissant un niveau de sécurité optimal.

---

## 1. Configuration Initiale

Pour commencer à utiliser l'application, vous devez configurer vos accès dans les **Réglages** :

- **Clé d'accès (Access Key)** : Identifiant fourni par votre fournisseur S3 (Amazon S3, Wasabi, Next.ink, etc.).
- **Clé secrète (Secret Key)** : Votre clé privée. Elle est stockée de manière sécurisée localement dans le **Trousseau d'accès (Keychain)** de votre appareil.
- **Endpoint** : L'adresse URL de votre service S3 (ex: `https://s3.fr1.next.ink`).
- **Nom du Bucket** : Le nom du compartiment où vous souhaitez travailler.
- **Région** : La région géographique de votre bucket (ex: `fr1`).

---

## 2. Navigation et Gestion des Fichiers

L'interface principale vous permet de parcourir vos données comme dans le Finder ou l'application Fichiers.

- **Navigation** : Cliquez sur un dossier pour entrer, ou utilisez le fil d'Ariane pour remonter.
- **Téléchargement** : Sélectionnez un fichier et utilisez l'icône de téléchargement. Sur iOS, vous pouvez ensuite enregistrer le fichier dans "Fichiers" ou le partager.
- **Upload** : Utilisez le bouton **"+"** pour choisir des fichiers ou des dossiers. Sur macOS, le glisser-déposer est également supporté.
- **Actions rapides** : Un clic droit (macOS) ou un appui long (iOS) sur un objet permet de le renommer, le supprimer ou consulter ses détails.

---

## 3. Fonctionnalités Avancées

### Chiffrement Client-Side (CSE)
S3 Next propose un chiffrement de bout en bout. Vos fichiers sont chiffrés **sur votre appareil** avant l'envoi.
1. Rendez-vous dans les **Réglages > Chiffrement**.
2. Générez ou importez une clé AES-256.
3. Lors de l'envoi, assurez-vous que la clé souhaitée est sélectionnée.
> **IMPORTANT** : Sans la clé de chiffrement originale, il est impossible de récupérer les données. Conservez vos alias et clés en lieu sûr (ou exportez-les).

### Gestion du Versioning
Si vous avez activé le versioning sur votre bucket (via les réglages S3 Next ou votre interface fournisseur) :
- Vous pouvez consulter chaque version archivée d'un fichier.
- Vous pouvez restaurer ou télécharger une ancienne version en cas d'erreur de manipulation.

### Maintenance des transferts
En cas de coupure réseau durant un upload important, des fragments de fichiers peuvent rester stockés sur le serveur (Multipart Uploads).
- Utilisez l'outil **Nettoyer les transferts abandonnés** dans les **Réglages > Maintenance** pour purger ces fragments et éviter des coûts de stockage inutiles.

---

## 4. Sécurité et Confidentialité

- **Stockage local** : Vos identifiants sensibles restent sur votre appareil.
- **Direct S3** : L'application communique directement avec votre fournisseur S3. Il n'y a aucun serveur intermédiaire (proxy) qui voit passer vos données.
- **RGPD** : Aucune donnée personnelle n'est collectée par l'application.

---

## 5. Support et Open Source

S3 Next est une application sous licence **GNU GPL v3**. Vous pouvez consulter, auditer ou contribuer au code source sur notre dépôt officiel :

[**Code source sur GitHub**](https://github.com/NaviStorm/S3-Next.git)

*Développé avec passion par Andreu-Ascensio Thierry.*
