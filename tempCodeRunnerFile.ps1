az storage account create `
  --name $TFSA --resource-group $TFRG --location $LOCATION `
  --sku Standard_ZRS --min-tls-version TLS1_2 `
  --allow-blob-public-access false --kind StorageV2