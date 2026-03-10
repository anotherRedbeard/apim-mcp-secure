#!/usr/bin/env bash
# Deletes the resource group and purges the soft-deleted APIM instance.
# Usage: ./scripts/cleanup.sh <resource-group> <apim-name> <apim-location>
set -euo pipefail

RG="${1:?Usage: $0 <resource-group> <apim-name> <apim-location>}"
APIM_NAME="${2:?}"
APIM_LOCATION="${3:?}"
SUB_ID=$(az account show --query id -o tsv)

echo "Deleting resource group '$RG'..."
az group delete --name "$RG" --yes

echo "Purging soft-deleted APIM instance '$APIM_NAME'..."
az rest --method DELETE \
  --url "/subscriptions/${SUB_ID}/providers/Microsoft.ApiManagement/locations/${APIM_LOCATION}/deletedservices/${APIM_NAME}?api-version=2022-08-01"

echo "Done! Redeploy with 'azd up'."
