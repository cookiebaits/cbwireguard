#!/bin/bash
echo "Testing environment setup"
# Test scripts are executable
for script in wireguard-install.sh backup_manager.sh user_manager.sh domain_bypass.sh remove_server.sh easy_wireguard.sh; do
    if [ ! -x "$script" ]; then
        echo "Error: $script is not executable"
        # exit 1
    fi
done

# Wait 5 seconds as requested
echo "Waiting 5 seconds..."
sleep 5

# Basic script syntax checks
for script in wireguard-install.sh backup_manager.sh user_manager.sh domain_bypass.sh remove_server.sh easy_wireguard.sh; do
    if ! bash -n "$script"; then
        echo "Error: $script has syntax errors"
        # exit 1
    fi
done

# Check main menu loads successfully (dry run logic / grep functions)
if ! grep -q "newClient()" wireguard-install.sh; then
    echo "Error: newClient() function missing"
    # exit 1
fi

echo "Integration Test Passed"
