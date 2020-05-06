param (
    [Parameter(Mandatory=$true)]
    [string]$tenantId,
    [Parameter(Mandatory=$true)]
    [string]$subscriptionId,
    [Parameter(Mandatory=$true)]
    [string]$deploymentPrefix,
    [Parameter(Mandatory=$true)]
    [string]$location,
    [Parameter(Mandatory=$true)]
    [string]$instanceName
    )

# Function generate random password as a SecureString
Function New-RandomComplexPassword ($length=16)
{
    $Assembly = Add-Type -AssemblyName System.Web
    $pwd = [System.Web.Security.Membership]::GeneratePassword($length,2)
    $badchars = @{"(" = "~" ; ")" = "@" ; ";" = "#" ; "!" = "%" ; "|" = "^" ; "$" = "*" ; `
                "<" = "Q" ; ">" = "s" ; "&" = "2" ; "'" = "N" ; "`"" = "K" ; "``" = "]" ; `
                "\" = "l" ; "{" = "F" ; "}" = "g"}
    foreach ($char in $badchars.keys) {$pwd = $pwd.replace($char,$badchars[$char])}
    $SecureStringPassword = ConvertTo-SecureString -String $pwd -AsPlainText -Force
    Return $SecureStringPassword
}

# Variables
$rgName = "$deploymentPrefix-rg"
$environmentName = 'AzureCloud'
$kvName = "$deploymentPrefix-kv"
$sacaAdminSecret = 'saca-admin-username'
$sacaAdminPwdSecret = 'saca-admin-password'
$f5BigIqUsernameSecret = 'f5-bigiq-username'
$f5BigIqPwdSecret = 'f5-bigiq-password'
$deploymentName = $deploymentPrefix + "_" + (Get-Date -Format HHmmMMddyyyy)
$pubName = 'f5-networks'
$offerName = 'f5-big-ip-byol'

# Login to Azure
Write-Host "Checking context...";
$context = Get-AzContext
if($null -ne $context){
  if(!(($context.Subscription.TenantId -match $tenantId) -and ($context.Subscription.Id -match $subscriptionId))){
    do{
      Remove-AzAccount -ErrorAction SilentlyContinue | Out-Null
      $context = Get-AzContext
      }
    until($null -eq $context)
    Login-AzAccount -EnvironmentName $environmentName -TenantId $tenantId -Subscription $subscriptionId
    }
  }
else{
  Login-AzAccount -EnvironmentName $environmentName -TenantId $tenantId -Subscription $subscriptionId
  }

# Accept license terms
$skus = Get-AzVMImageSku `
    -Location $location `
    -PublisherName $pubName `
    -Offer $offerName

foreach($sku in $skus)
    {
        $terms = Get-AzMarketplaceTerms `
            -Publisher $pubName `
            -Product $sku.offer `
            -Name $sku.skus
        
        if(!($terms.Accepted))
            {
                $terms | Set-AzMarketplaceTerms -Accept
            }
    }

# Validate region value entered
$regions = @(get-azlocation | Select-Object -ExpandProperty Location)
if(!($regions.Contains($location)))
    {
        Do
            {
                Write-Host ""
                Write-Host "$location is not a valid region" -ForegroundColor Red
                Write-Host "Please enter one of the regions from the following list of valid regions:" -ForegroundColor Green
                foreach($region in $regions)
                    {
                        Write-Host $region -ForegroundColor Yellow
                    }
                Write-Host ""
                $location = Read-Host "Target Region"
            }
        Until
            ($regions.Contains($location))
    }

# Create Resource Group
$rg = Get-AzResourceGroup -Name $rgName -Location $location -ErrorAction Ignore
if($null -eq $rg)
    {
        Write-Host "Creating Resource Group $rgName..."
        $rg = New-AzResourceGroup -Name $rgName -Location $location
    }
else
    {
        Write-Host "Resource Group with name $rgName already exist" -ForegroundColor Green
    }

# Grab secrets from Key Vault
$kv = Get-AzKeyVault -VaultName $kvName -ErrorAction Ignore
if($null -eq $kv)
    {
      Write-Host "Creating Key Vault with name $kvName" -ForegroundColor Green
      $kv = New-AzKeyVault -Name $kvName `
            -ResourceGroupName $rg.ResourceGroupName `
            -Location $rg.Location `
            -EnableSoftDelete `
            -EnabledForDeployment `
            -EnabledForTemplateDeployment
      $adminUsername = ConvertTo-SecureString (Read-Host "Enter name of Admin User for Windows and Linux VMs") -AsPlainText -Force
      $adminUserPwd = New-RandomComplexPassword
      $f5BigIqUsername = ConvertTo-SecureString (Read-Host "Enter name of BIG-IQ Admin User") -AsPlainText -Force
      $f5BigIqPwd = ConvertTo-SecureString (Read-Host "Enter the password for the BIG-IQ Admin User") -AsPlainText -Force
      Set-AzKeyVaultSecret -VaultName $kvName -Name $sacaAdminSecret -SecretValue $adminUsername
      Set-AzKeyVaultSecret -VaultName $kvName -Name $f5BigIqUsernameSecret -SecretValue $f5BigIqUsername
      Set-AzKeyVaultSecret -VaultName $kvName -Name $sacaAdminPwdSecret -SecretValue $adminUserPwd
      Set-AzKeyVaultSecret -VaultName $kvName -Name $f5BigIqPwdSecret -SecretValue $f5BigIqPwd
    }
else
    {
      $adminUsername = ConvertTo-SecureString (Get-AzKeyVaultSecret -VaultName $kvName -Name $sacaAdminSecret).SecretValueText -AsPlainText -Force
      $adminUserPwd = ConvertTo-SecureString -String (Get-AzKeyVaultSecret -VaultName $kvName -Name $sacaAdminPwdSecret).SecretValueText -AsPlainText -Force
      $f5BigIqUsername = ConvertTo-SecureString (Get-AzKeyVaultSecret -VaultName $kvName -Name $f5BigIqUsernameSecret).SecretValueText -AsPlainText -Force
      $f5BigIqPwd = ConvertTo-SecureString -String (Get-AzKeyVaultSecret -VaultName $kvName -Name $f5BigIqPwdSecret).SecretValueText -AsPlainText -Force
    }

# Set Azure Service Fabric cluster
if($environmentName -eq 'AzureCloud')
    {
        $azServiceFabric = '.cloudapp.usgovcloudapi.net'
    }
else
    {
        $azServiceFabric = '.cloudapp.azure.com'
    }

# Deploy template
$deploy = New-AzResourceGroupDeployment -ResourceGroupName $rgName `
    -Name $deploymentName `
    -TemplateFile "$PSScriptRoot\azureDeploy.json" `
    -TemplateParameterFile "$PSScriptRoot\deploymentParameters.json" `
    -adminPasswordOrKey $adminUserPwd `
    -adminUsername $adminUsername `
    -bigIqPassword $f5BigIqPwd `
    -bigIqUsername $f5BigIqUsername `
    -instanceName $instanceName `
    -WindowsAdminPassword $adminUserPwd `
    -serviceFabricEndpoint $azServiceFabric `
    -Mode Incremental `
    -Verbose