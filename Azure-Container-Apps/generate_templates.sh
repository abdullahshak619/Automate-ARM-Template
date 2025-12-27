#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

INPUT_FILE="$1"

if [ -z "$INPUT_FILE" ]; then
    echo -e "${RED}Usage: $0 <path-to-variable.json>${NC}"
    exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo -e "${RED}Error: $INPUT_FILE not found!${NC}"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

echo -e "${BLUE}Loading variables from $INPUT_FILE...${NC}"

# Get the directory where the variable file is located
OUTPUT_DIR=$(dirname "$INPUT_FILE")

# Output files will be in the same directory as the variable file
TEMPLATE_FILE="$OUTPUT_DIR/template.json"
PARAMS_FILE="$OUTPUT_DIR/parameters.json"

# Read variables
SUBSCRIPTION_ID=$(jq -r '.subscription.id' "$INPUT_FILE")
RESOURCE_GROUP=$(jq -r '.resourceGroup.name' "$INPUT_FILE")
KEY_VAULT=$(jq -r '.keyVault.name' "$INPUT_FILE")
ACR_SERVER=$(jq -r '.acr.server' "$INPUT_FILE")
ACR_USERNAME=$(jq -r '.acr.username' "$INPUT_FILE")
RUNTIME_MI=$(jq -r '.managedIdentities.runtime' "$INPUT_FILE")
DEPLOYMENT_MI=$(jq -r '.managedIdentities.deployment' "$INPUT_FILE")
LOCATION=$(jq -r '.containerApp.location' "$INPUT_FILE")
CONTAINER_NAME=$(jq -r '.containerApp.name' "$INPUT_FILE")
IMAGE_NAME=$(jq -r '.containerApp.imageName' "$INPUT_FILE")
TARGET_PORT=$(jq -r '.containerApp.targetPort' "$INPUT_FILE")
MANAGED_ENV=$(jq -r '.containerApp.managedEnvironmentName' "$INPUT_FILE")
INGRESS_ENABLED=$(jq -r '.containerApp.ingress.enabled' "$INPUT_FILE")
INGRESS_EXTERNAL=$(jq -r '.containerApp.ingress.external' "$INPUT_FILE")
INGRESS_TRANSPORT=$(jq -r '.containerApp.ingress.transport' "$INPUT_FILE")
INGRESS_ALLOW_INSECURE=$(jq -r '.containerApp.ingress.allowInsecure' "$INPUT_FILE")

# Build resource IDs
RUNTIME_MI_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$RUNTIME_MI"
DEPLOYMENT_MI_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$DEPLOYMENT_MI"
MANAGED_ENV_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.App/managedEnvironments/$MANAGED_ENV"
KEY_VAULT_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT"

echo -e "${BLUE}Generating ARM template...${NC}"

# Generate ARM Template with all parameters dynamically
cat > "$TEMPLATE_FILE" << 'EOF'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "acrServer": { "type": "string" },
    "acrUsername": { "type": "string" },
    "acrPassword": { "type": "securestring" },
    "location": { "type": "string" },
    "managedEnvironmentId": { "type": "string" },
    "imageName": { "type": "string" },
    "containerName": { "type": "string" },
    "targetPort": { "type": "int" },
    "runtimeManagedIdentityId": { "type": "string" },
    "deploymentManagedIdentityId": { "type": "string" },
    "ingressEnabled": { "type": "bool" },
    "ingressExternal": { "type": "bool" },
    "ingressTransport": { "type": "string" },
    "ingressAllowInsecure": { "type": "bool" },
    "registryServer": { "type": "string" },
    "registryIdentity": { "type": "string" }
EOF

# Add secret parameters dynamically
jq -r '.environmentVariables.secrets | keys[] | select(. != "acrPassword")' "$INPUT_FILE" | while read secret; do
    cat >> "$TEMPLATE_FILE" << EOF
    ,"$secret": { "type": "securestring" }
EOF
done

# Add non-secret parameters dynamically
jq -r '.environmentVariables.nonSecrets | keys[]' "$INPUT_FILE" | while read param; do
    cat >> "$TEMPLATE_FILE" << EOF
    ,"$param": { "type": "string" }
EOF
done

# Build secrets array
cat >> "$TEMPLATE_FILE" << EOF
  },
  "resources": [
    {
      "type": "Microsoft.App/containerApps",
      "apiVersion": "2023-05-01",
      "name": "[parameters('containerName')]",
      "location": "[parameters('location')]",
      "identity": {
        "type": "UserAssigned",
        "userAssignedIdentities": {
          "[parameters('runtimeManagedIdentityId')]": {},
          "[parameters('deploymentManagedIdentityId')]": {}
        }
      },
      "properties": {
        "managedEnvironmentId": "[parameters('managedEnvironmentId')]",
        "configuration": {
          "secrets": [
            { "name": "acr-password", "value": "[parameters('acrPassword')]" }
EOF

# Add secrets dynamically
jq -r '.environmentVariables.secrets | keys[] | select(. != "acrPassword")' "$INPUT_FILE" | while read secret; do
    SECRET_NAME=$(echo "$secret" | tr '[:upper:]_' '[:lower:]-')
    cat >> "$TEMPLATE_FILE" << EOF
            ,{ "name": "$SECRET_NAME", "value": "[parameters('$secret')]" }
EOF
done

# Continue with configuration
cat >> "$TEMPLATE_FILE" << EOF
          ],
          "activeRevisionsMode": "Single",
          "ingress": "[if(parameters('ingressEnabled'), createObject('external', parameters('ingressExternal'), 'targetPort', parameters('targetPort'), 'transport', parameters('ingressTransport'), 'allowInsecure', parameters('ingressAllowInsecure'), 'traffic', createArray(createObject('weight', 100, 'latestRevision', true()))), null())]",
          "registries": [
            {
              "server": "[parameters('registryServer')]",
              "identity": "[parameters('registryIdentity')]"
            }
          ]
        },
        "template": {
          "containers": [
            {
              "image": "[parameters('imageName')]",
              "name": "[parameters('containerName')]",
              "resources": $(jq '.containerApp.resources' "$INPUT_FILE"),
              "command": $(jq '.startupCommand.command' "$INPUT_FILE" | jq -s),
              "args": $(jq '.startupCommand.args' "$INPUT_FILE"),
              "env": [
EOF

# Add secret env vars
FIRST=true
jq -r '.environmentVariables.secrets | keys[] | select(. != "acrPassword")' "$INPUT_FILE" | while read secret; do
    SECRET_NAME=$(echo "$secret" | tr '[:upper:]_' '[:lower:]-')
    if [ "$FIRST" = false ]; then echo "," >> "$TEMPLATE_FILE"; fi
    cat >> "$TEMPLATE_FILE" << EOF
                { "name": "$secret", "secretRef": "$SECRET_NAME" }
EOF
    FIRST=false
done

# Add non-secret env vars
jq -r '.environmentVariables.nonSecrets | keys[]' "$INPUT_FILE" | while read env; do
    echo "," >> "$TEMPLATE_FILE"
    cat >> "$TEMPLATE_FILE" << EOF
                { "name": "$env", "value": "[parameters('$env')]" }
EOF
done

# Add volume mounts
echo "              ]," >> "$TEMPLATE_FILE"
echo '              "volumeMounts": [' >> "$TEMPLATE_FILE"

FIRST=true
jq -c '.volumes[]' "$INPUT_FILE" 2>/dev/null | while read vol; do
    NAME=$(echo "$vol" | jq -r '.name')
    MOUNT=$(echo "$vol" | jq -r '.mountPath')
    if [ "$FIRST" = false ]; then echo "," >> "$TEMPLATE_FILE"; fi
    cat >> "$TEMPLATE_FILE" << EOF
                { "mountPath": "$MOUNT", "volumeName": "$NAME" }
EOF
    FIRST=false
done

# Complete container definition and add volumes
cat >> "$TEMPLATE_FILE" << EOF
              ]
            }
          ],
          "scale": $(jq '.containerApp.scaling' "$INPUT_FILE" | jq '. + {rules: []}'),
          "volumes": [
EOF

# Add volumes
FIRST=true
jq -c '.volumes[]' "$INPUT_FILE" 2>/dev/null | while read vol; do
    NAME=$(echo "$vol" | jq -r '.name')
    STORAGE=$(echo "$vol" | jq -r '.storageName')
    if [ "$FIRST" = false ]; then echo "," >> "$TEMPLATE_FILE"; fi
    cat >> "$TEMPLATE_FILE" << EOF
            { "name": "$NAME", "storageType": "AzureFile", "storageName": "$STORAGE" }
EOF
    FIRST=false
done

# Close template
cat >> "$TEMPLATE_FILE" << EOF
          ]
        }
      }
    }
  ]
}
EOF

echo -e "${GREEN}✓ Generated $TEMPLATE_FILE${NC}"

# Generate Parameters File
echo -e "${BLUE}Generating parameters file...${NC}"

cat > "$PARAMS_FILE" << EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "acrServer": { "value": "$ACR_SERVER" },
    "acrUsername": { "value": "$ACR_USERNAME" },
    "acrPassword": {
      "reference": {
        "keyVault": { "id": "$KEY_VAULT_ID" },
        "secretName": "$(jq -r '.environmentVariables.secrets.acrPassword.keyVaultSecret' "$INPUT_FILE")"
      }
    },
    "location": { "value": "$LOCATION" },
    "managedEnvironmentId": { "value": "$MANAGED_ENV_ID" },
    "imageName": { "value": "$IMAGE_NAME" },
    "containerName": { "value": "$CONTAINER_NAME" },
    "targetPort": { "value": $TARGET_PORT },
    "runtimeManagedIdentityId": { "value": "$RUNTIME_MI_ID" },
    "deploymentManagedIdentityId": { "value": "$DEPLOYMENT_MI_ID" },
    "ingressEnabled": { "value": $INGRESS_ENABLED },
    "ingressExternal": { "value": $INGRESS_EXTERNAL },
    "ingressTransport": { "value": "$INGRESS_TRANSPORT" },
    "ingressAllowInsecure": { "value": $INGRESS_ALLOW_INSECURE },
    "registryServer": { "value": "$ACR_SERVER" },
    "registryIdentity": { "value": "$DEPLOYMENT_MI_ID" }
EOF

# Add secrets from Key Vault
jq -r '.environmentVariables.secrets | keys[] | select(. != "acrPassword")' "$INPUT_FILE" | while read secret; do
    KV_SECRET=$(jq -r ".environmentVariables.secrets.$secret.keyVaultSecret" "$INPUT_FILE")
    cat >> "$PARAMS_FILE" << EOF
    ,"$secret": {
      "reference": {
        "keyVault": { "id": "$KEY_VAULT_ID" },
        "secretName": "$KV_SECRET"
      }
    }
EOF
done

# Add non-secret parameters
jq -r '.environmentVariables.nonSecrets | to_entries[] | "\(.key)=\(.value)"' "$INPUT_FILE" | while IFS='=' read -r key value; do
    cat >> "$PARAMS_FILE" << EOF
    ,"$key": { "value": "$value" }
EOF
done

# Close parameters file
cat >> "$PARAMS_FILE" << EOF
  }
}
EOF

echo -e "${GREEN}✓ Generated $PARAMS_FILE${NC}"
echo ""
echo -e "${GREEN}✅ Templates generated in: $OUTPUT_DIR/${NC}"
