#!/usr/bin/env bash
set -e

echo "===================================="
echo " Shaper Compact Installer "
echo "===================================="

echo ""
echo "User: $(whoami)"
echo "Home: $HOME"
echo "Hostname: $(hostname)"
echo ""

# Verifica che non sia root
if [ "$EUID" -eq 0 ]; then
  echo "❌ Non eseguire come root."
  echo "Esegui come utente normale."
  exit 1
fi

echo "✅ Script avviato correttamente."
echo "Questa è solo una prova: nessuna modifica al sistema."
echo ""
echo "Next step: aggiungere installazione vera."
