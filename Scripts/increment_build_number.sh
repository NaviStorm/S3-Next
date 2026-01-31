#!/bin/bash

# Ce script incrémente automatiquement le numéro de build (CFBundleVersion)
# Il utilise l'outil officiel Apple 'agvtool'.

# Se placer dans le répertoire du projet
cd "${PROJECT_DIR}"

# Incrémenter le numéro de build pour toutes les cibles
xcrun agvtool next-version -all
