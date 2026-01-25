# S3 Next

**S3 Next** est un client S3 moderne, performant et élégant, conçu nativement pour macOS et iOS avec SwiftUI. Il offre une interface intuitive pour gérer vos buckets S3 tout en garantissant un haut niveau de sécurité et de confidentialité.

![Version macOS](https://img.shields.io/badge/Platform-macOS%2013.0+-blue.svg)
![Version iOS](https://img.shields.io/badge/Platform-iOS%2016.0+-blue.svg)
![License](https://img.shields.io/badge/License-GNU%20GPL%20v3-green.svg)

---

## ✨ Fonctionnalités

### 🖥️ Expérience Native
- **macOS** : Une véritable application de bureau avec support du glisser-déposer, raccourcis clavier natifs et fenêtres multiples.
- **iOS** : Une interface mobile fluide avec intégration complète du partage système et de la photothèque.

### 🛡️ Sécurité & Confidentialité
- **Chiffrement Client-Side (CSE)** : Chiffrez vos fichiers localement avant l'envoi vers le cloud. Vos données sont illisibles pour le fournisseur S3.
- **Gestion du Trousseau (Keychain)** : Vos clés d'accès ne sont jamais stockées en clair. Elles sont protégées par le système de sécurité natif d'Apple.
- **Zéro Intermédiaire** : L'application communique directement avec votre fournisseur S3 sans aucun serveur tiers.

### 📂 Gestion de Données Avancée
- **Navigateur complet** : Parcourez, créez, renommez et supprimez vos objets S3 en toute simplicité.
- **Gestion du Versioning** : Visualisez l'historique de vos fichiers et restaurez d'anciennes versions en un clic.
- **Support Multipart** : Téléchargez et envoyez des fichiers volumineux avec reprise automatique en cas d'interruption.
- **Maintenance** : Outil intégré pour nettoyer les transferts interrompus et optimiser votre stockage.

---

## 🚀 Installation

L'application est disponible via le déploiement TestFlight et l'App Store.

### Prérequis
- **macOS** : Version 13.0 ou ultérieure.
- **iOS** : Version 16.0 ou ultérieure.

### Configuration
1. Lancez l'application.
2. Accédez aux **Réglages**.
3. Renseignez votre **Access Key**, **Secret Key**, **Endpoint** et le nom de votre **Bucket**.
4. Cliquez sur **Connecter**.

---

## 🛠️ Technologies

- **Langage** : Swift
- **Interface** : SwiftUI (Architecture Multiplateforme)
- **Réseau** : URLSession avec signature AWS V4 native.
- **Stockage local** : Persistence via Keychain et AppStorage.

---

## 📜 Licence

Ce projet est distribué sous la licence **GNU GPL v3**. Vous êtes libre de consulter, modifier et redistribuer le code source dans le respect des termes de cette licence.

---

## 👨‍💻 Auteur

Développé par **Andreu-Ascensio Thierry**.

[**Code source sur GitHub**](https://github.com/NaviStorm/S3-Next.git)
