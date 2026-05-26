# Docker initialization script for Windows - creates necessary directories and validates configs

Write-Host "Initializing Docker environment..." -ForegroundColor Cyan
Write-Host ""

# Create directories for all 5 accounts
$accounts = @("account1", "account2", "account3", "account4", "account5")

foreach ($account in $accounts) {
    $configDir = "configs\$account"
    $cookieDir = "cookies\$account"
    $logDir = "logs\$account"
    
    # Create config directory
    if (!(Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-Host "✓ Created: $configDir" -ForegroundColor Green
    } else {
        Write-Host "✓ Exists: $configDir" -ForegroundColor Gray
    }
    
    # Create cookies directory
    if (!(Test-Path $cookieDir)) {
        New-Item -ItemType Directory -Path $cookieDir -Force | Out-Null
        Write-Host "✓ Created: $cookieDir" -ForegroundColor Green
    } else {
        Write-Host "✓ Exists: $cookieDir" -ForegroundColor Gray
    }
    
    # Create logs directory
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Write-Host "✓ Created: $logDir" -ForegroundColor Green
    } else {
        Write-Host "✓ Exists: $logDir" -ForegroundColor Gray
    }
    
    # Check if config exists for this account
    $configFile = "$configDir\config.json"
    if (!(Test-Path $configFile)) {
        Write-Host "⚠ Warning: $configFile not found!" -ForegroundColor Yellow
    } else {
        # Check if username is configured
        $configContent = Get-Content $configFile -Raw | ConvertFrom-Json
        if ($configContent.username -match "TWITCH-USERNAME|your-twitch-username") {
            Write-Host "⚠ Warning: $configFile has placeholder username - please update!" -ForegroundColor Yellow
        } else {
            Write-Host "✓ Config OK: $configFile" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "Initialization complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Edit configs/account1/config.json through account5/config.json with your Twitch usernames" -ForegroundColor White
Write-Host "2. Run: docker-compose up -d" -ForegroundColor White
Write-Host "3. Check logs: docker-compose logs -f" -ForegroundColor White
Write-Host "4. Stop: docker-compose down" -ForegroundColor White
Write-Host ""