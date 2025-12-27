#!/bin/bash

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

show_usage() {
    echo -e "${BLUE}Usage:${NC}"
    echo "  $0 <app-folder|all> <resource-group>"
    echo ""
    echo -e "${YELLOW}⚠️  The resource group MUST match what's in your *_variable.json file!${NC}"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  #  Deploy in resource group, eg:"
    echo "  $0 gps_sales my-prod-rg"
    echo "  $0 gps_sales_ui staging-rg"
    echo "  $0 all staging-rg"
    echo ""
}

if [ $# -ne 2 ]; then
    echo -e "${RED}❌ Error: Invalid arguments${NC}"
    echo ""
    show_usage
    exit 1
fi

APP_INPUT=$1
RESOURCE_GROUP=$2

echo -e "${BLUE}════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Azure Container Apps Deployment${NC}"
echo -e "${BLUE}════════════════════════════════════════════${NC}"
echo ""

# Function to deploy a single app
deploy_app() {
    local APP_FOLDER=$1
    local RESOURCE_GROUP=$2
    
    if [ ! -d "$APP_FOLDER" ]; then
        echo -e "${RED}❌ Error: Folder '$APP_FOLDER' not found${NC}"
        return 1
    fi
    
    # Find variable JSON file in the folder
    VARIABLE_FILE=$(find "$APP_FOLDER" -name "*_variable.json" -o -name "variable.json" | head -n 1)
    
    if [ -z "$VARIABLE_FILE" ]; then
        echo -e "${RED}❌ Error: No variable.json file found in $APP_FOLDER${NC}"
        return 1
    fi
    
    echo -e "${BLUE}📦 Deploying: $APP_FOLDER${NC}"
    echo -e "${BLUE}📄 Config: $VARIABLE_FILE${NC}"
    echo ""
    
    # Validate resource group
    CONFIG_RG=$(jq -r '.resourceGroup.name' "$VARIABLE_FILE")
    
    if [ "$CONFIG_RG" = "null" ]; then
        echo -e "${RED}❌ Error: resourceGroup.name not found in $VARIABLE_FILE${NC}"
        return 1
    fi
    
    if [ "$CONFIG_RG" != "$RESOURCE_GROUP" ]; then
        echo -e "${RED}❌ Error: Resource group mismatch!${NC}"
        echo -e "${RED}   Expected (from config): $CONFIG_RG${NC}"
        echo -e "${RED}   Provided: $RESOURCE_GROUP${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Resource group validated: $RESOURCE_GROUP${NC}"
    echo ""
    
    # Generate templates
    echo -e "${BLUE}🔧 Generating templates...${NC}"
    ./generate_templates.sh "$VARIABLE_FILE"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Template generation failed${NC}"
        return 1
    fi
    
    # Template files are in the same folder as variable file
    TEMPLATE_FILE="$APP_FOLDER/template.json"
    PARAMS_FILE="$APP_FOLDER/parameters.json"
    
    if [ ! -f "$TEMPLATE_FILE" ] || [ ! -f "$PARAMS_FILE" ]; then
        echo -e "${RED}❌ Error: Generated files not found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Templates generated:${NC}"
    echo -e "   📄 $TEMPLATE_FILE"
    echo -e "   📄 $PARAMS_FILE"
    echo ""
    
    # Deploy
    APP_NAME=$(jq -r '.containerApp.name' "$VARIABLE_FILE")
    DEPLOYMENT_NAME="${APP_NAME}-$(date +%Y%m%d-%H%M%S)"
    
    echo -e "${BLUE}🚀 Deploying to Azure...${NC}"
    echo -e "${BLUE}   App: $APP_NAME${NC}"
    echo -e "${BLUE}   RG: $RESOURCE_GROUP${NC}"
    echo ""
    
    az deployment group create \
        --name "$DEPLOYMENT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$TEMPLATE_FILE" \
        --parameters "$PARAMS_FILE" \
        --output table
    
    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✅ Successfully deployed: $APP_NAME${NC}"
        echo ""
        return 0
    else
        echo -e "${RED}❌ Deployment failed: $APP_NAME${NC}"
        return 1
    fi
}


# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ Error: jq is required but not installed.${NC}"
    echo "Install with: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

# Deploy based on input
if [ "$APP_INPUT" = "all" ]; then
    echo -e "${YELLOW}📦 Deploying ALL apps${NC}"
    echo ""
    
    # Find all folders with variable.json files
    APP_FOLDERS=$(find . -maxdepth 2 \( -name "*_variable.json" -o -name "variable.json" \) \
  -exec dirname {} \; | sort -u)

    echo "DEBUG: APP_FOLDERS = $APP_FOLDERS"

    
    if [ -z "$APP_FOLDERS" ]; then
        echo -e "${RED}❌ No app folders found with variable.json files${NC}"
        exit 1
    fi
    
    SUCCESS_COUNT=0
    FAILED_COUNT=0
    TOTAL_COUNT=0
    
    for APP_FOLDER in $APP_FOLDERS; do
        ((TOTAL_COUNT++))
        if deploy_app "$APP_FOLDER" "$RESOURCE_GROUP"; then
            ((SUCCESS_COUNT++))
        else
            ((FAILED_COUNT++))
        fi
        echo ""
    done
    
    # Summary
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Deployment Summary${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ Successful: $SUCCESS_COUNT${NC}"
    if [ $FAILED_COUNT -gt 0 ]; then
        echo -e "${RED}❌ Failed: $FAILED_COUNT${NC}"
    fi
    echo -e "${BLUE}📦 Total: $TOTAL_COUNT${NC}"
    
    if [ $FAILED_COUNT -gt 0 ]; then
        exit 1
    fi
else
    # Deploy single app
    deploy_app "$APP_INPUT" "$RESOURCE_GROUP"
fi
 
