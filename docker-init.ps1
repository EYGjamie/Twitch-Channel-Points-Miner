# Docker initialization script creates necessary directories

Write-Host "Initializing Docker directories..." -ForegroundColor Cyan

# Create directories for 5 accounts
$accounts = 1..5 | ForEach-Object { "account$_" }

foreach ($account in $accounts) {
    $cookieDir = "cookies\$account"
    $logDir = "logs\$account"
    
    if (!(Test-Path $cookieDir)) {
        New-Item -ItemType Directory -Path $cookieDir -Force | Out-Null
        Write-Host "✓ Created: $cookieDir" -ForegroundColor Green
    } else {
        Write-Host "✓ Exists: $cookieDir" -ForegroundColor Gray
    }
    
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Write-Host "✓ Created: $logDir" -ForegroundColor Green
    } else {
        Write-Host "✓ Exists: $logDir" -ForegroundColor Gray
    }
}

# Check if config.json exists
if (!(Test-Path "config.json")) {
    Write-Host "⚠ Warning: config.json not found!" -ForegroundColor Yellow
    Write-Host "  Please create a config.json in the root directory." -ForegroundColor Yellow
} else {
    Write-Host "✓ config.json found" -ForegroundColor Green
}

Write-Host "`nInitialization complete!" -ForegroundColor Green
Write-Host "You can now run 'docker-compose up -d'." -ForegroundColor Cyan