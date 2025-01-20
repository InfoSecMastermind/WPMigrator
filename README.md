# WordPress Migrator Script (wpmigrator.sh)

This script facilitates the migration of your WordPress and WooCommerce sites from **Cloudways** to your local machine or custom server.

## Requirements

- Linux or macOS system (or WSL on Windows).
- **bash** shell (comes pre-installed on most systems).
- A working installation of **WordPress** and **WooCommerce**.
- **Cloudways** account details.

## Script Overview

The script will prompt you for your **Cloudways** server details, your local server/database information, and then migrate the necessary files and database from Cloudways to your local server.

## Setup and Usage

1. **Download the script**:  
   Download the `wpmigrator.sh` script to your local machine.

2. **Make the script executable**:  
   Open your terminal and navigate to the directory where the script is located. Run the following command to make it executable, then execute it:

   ```bash
   chmod +x wpmigrator.sh
   ./wpmigrator.sh
