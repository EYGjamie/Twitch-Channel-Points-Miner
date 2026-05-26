#!/bin/bash

# Docker initialization script for Linux - creates necessary directories and validates configs

echo -e "\033[0;36mInitializing Docker environment...\033[0m"
echo ""

# Create directories for all 5 accounts
accounts=("account1" "account2" "account3" "account4" "account5")

for account in "${accounts[@]}"; do
    config_dir="configs/$account"
    cookie_dir="cookies/$account"
    log_dir="logs/$account"
    
    # Create config directory
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
        echo -e "\033[0;32m✓ Created: $config_dir\033[0m"
    else
        echo -e "\033[0;90m✓ Exists: $config_dir\033[0m"
    fi
    
    # Create cookies directory
    if [ ! -d "$cookie_dir" ]; then
        mkdir -p "$cookie_dir"
        echo -e "\033[0;32m✓ Created: $cookie_dir\033[0m"
    else
        echo -e "\033[0;90m✓ Exists: $cookie_dir\033[0m"
    fi
    
    # Create logs directory
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        echo -e "\033[0;32m✓ Created: $log_dir\033[0m"
    else
        echo -e "\033[0;90m✓ Exists: $log_dir\033[0m"
    fi
    
    # Check if config exists for this account
    config_file="$config_dir/config.json"
    if [ ! -f "$config_file" ]; then
        echo -e "\033[0;33m⚠ Warning: $config_file not found!\033[0m"
    else
        # Check if username is configured (Linux compatible)
        if grep -q "TWITCH-USERNAME\|your-twitch-username" "$config_file"; then
            echo -e "\033[0;33m⚠ Warning: $config_file has placeholder username - please update!\033[0m"
        else
            echo -e "\033[0;32m✓ Config OK: $config_file\033[0m"
        fi
    fi
done

echo ""
echo -e "\033[0;32mInitialization complete!\033[0m"
echo ""
echo -e "\033[0;36mNext steps:\033[0m"
echo -e "\033[0;37m1. Edit configs/account1/config.json through account5/config.json with your Twitch usernames\033[0m"
echo -e "\033[0;37m2. Run: docker-compose up -d\033[0m"
echo -e "\033[0;37m3. Check logs: docker-compose logs -f\033[0m"
echo -e "\033[0;37m4. Stop: docker-compose down\033[0m"
echo ""
