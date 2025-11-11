#!/bin/sh
# Docker handling script - POSIX compatible

# Colors for better readability (optional, works in most terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect OS
detect_os() {
    OS_TYPE=$(uname -s)
    case "$OS_TYPE" in
        Darwin*)
            OS="macos"
            ;;
        Linux*)
            OS="linux"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            OS="windows"
            ;;
        *)
            OS="unknown"
            ;;
    esac
}

# Function to print colored messages
print_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

print_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

# Function to check if colima is running and start if not
check_and_start_colima() {
    print_info "Detected OS: $OS ($OS_TYPE)"
    printf "\n"
    
    # Colima is only relevant for macOS
    if [ "$OS" != "macos" ]; then
        print_warning "Colima is only used on macOS."
        print_info "On $OS, Docker should be running natively or via Docker Desktop."
        
        # Check if docker is accessible
        if command -v docker >/dev/null 2>&1; then
            if docker info >/dev/null 2>&1; then
                print_success "Docker is running and accessible"
            else
                print_error "Docker command found but not responding. Is Docker running?"
            fi
        else
            print_error "Docker is not installed or not in PATH"
        fi
        return 0
    fi
    
    # macOS-specific Colima handling
    print_info "Checking Colima status..."
    
    # Check if colima is installed
    if ! command -v colima >/dev/null 2>&1; then
        print_error "Colima is not installed. Please install it first."
        printf "Visit: https://github.com/abiosoft/colima\n"
        printf "Install via: brew install colima\n"
        return 1
    fi
    
    # Check if colima is running
    if colima status >/dev/null 2>&1; then
        print_success "Colima is already running"
        colima status
    else
        print_warning "Colima is not running. Starting Colima..."
        if colima start; then
            print_success "Colima started successfully"
        else
            print_error "Failed to start Colima"
            return 1
        fi
    fi
    
    return 0
}

# Function to list docker images
list_docker_images() {
    print_info "Listing Docker images..."
    
    # Check if docker is available
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker command not found"
        return 1
    fi
    
    # Try to list images
    if ! docker images; then
        print_error "Failed to list Docker images. Is Docker running?"
        return 1
    fi
    
    return 0
}

# Function to list docker processes (containers)
list_docker_processes() {
    print_info "Listing Docker Processes (Containers)..."
    printf "\n"
    
    # Check if docker is available
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker command not found"
        return 1
    fi
    
    # Show running containers
    print_info "Running containers:"
    if ! docker ps; then
        print_error "Failed to list running containers. Is Docker running?"
        return 1
    fi
    
    printf "\n"
    printf "Show all containers (including stopped)? (y/n): "
    read -r show_all
    
    if [ "$show_all" = "y" ] || [ "$show_all" = "Y" ]; then
        printf "\n"
        print_info "All containers (including stopped):"
        if ! docker ps -a; then
            print_error "Failed to list all containers"
            return 1
        fi
        
        # Offer container management options
        printf "\n"
        printf "Container Management Options:\n"
        printf "  1) Remove stopped container by ID\n"
        printf "  2) Remove stopped container by name\n"
        printf "  3) Remove all stopped containers\n"
        printf "  4) Force remove running container\n"
        printf "  0) Back to main menu\n"
        printf "\n"
        printf "Enter your choice: "
        read -r container_choice
        
        case "$container_choice" in
            1)
                printf "Enter CONTAINER ID: "
                read -r container_id
                if [ -z "$container_id" ]; then
                    print_error "CONTAINER ID cannot be empty"
                    return 1
                fi
                
                # Check if container exists and is stopped
                status=$(docker ps -a --filter "id=$container_id" --format "{{.Status}}" 2>/dev/null)
                if [ -z "$status" ]; then
                    print_error "Container not found: $container_id"
                    return 1
                fi
                
                print_warning "About to remove container: $container_id"
                printf "Are you sure? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    if docker rm "$container_id"; then
                        print_success "Container removed successfully"
                    else
                        print_error "Failed to remove container. Try force remove? (y/n): "
                        read -r force_choice
                        if [ "$force_choice" = "y" ] || [ "$force_choice" = "Y" ]; then
                            docker rm -f "$container_id"
                            print_success "Container force removed"
                        fi
                    fi
                else
                    print_info "Operation cancelled"
                fi
                ;;
            2)
                printf "Enter CONTAINER NAME: "
                read -r container_name
                if [ -z "$container_name" ]; then
                    print_error "CONTAINER NAME cannot be empty"
                    return 1
                fi
                
                # Check if container exists
                status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}" 2>/dev/null)
                if [ -z "$status" ]; then
                    print_error "Container not found: $container_name"
                    return 1
                fi
                
                print_warning "About to remove container: $container_name"
                printf "Are you sure? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    if docker rm "$container_name"; then
                        print_success "Container removed successfully"
                    else
                        print_error "Failed to remove container. Try force remove? (y/n): "
                        read -r force_choice
                        if [ "$force_choice" = "y" ] || [ "$force_choice" = "Y" ]; then
                            docker rm -f "$container_name"
                            print_success "Container force removed"
                        fi
                    fi
                else
                    print_info "Operation cancelled"
                fi
                ;;
            3)
                # Get list of stopped containers
                stopped_containers=$(docker ps -a -q -f status=exited 2>/dev/null)
                
                if [ -z "$stopped_containers" ]; then
                    print_info "No stopped containers found"
                    return 0
                fi
                
                printf "\n"
                print_info "Stopped containers:"
                docker ps -a -f status=exited
                printf "\n"
                
                print_warning "This will remove ALL stopped containers"
                printf "Are you sure? (y/n): "
                read -r confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    print_info "Removing stopped containers..."
                    if docker container prune -f; then
                        print_success "All stopped containers removed successfully"
                    else
                        print_error "Failed to remove stopped containers"
                        return 1
                    fi
                else
                    print_info "Operation cancelled"
                fi
                ;;
            4)
                printf "Enter CONTAINER ID or NAME to force remove: "
                read -r container_ref
                if [ -z "$container_ref" ]; then
                    print_error "CONTAINER reference cannot be empty"
                    return 1
                fi
                
                # Check if container exists
                status=$(docker ps -a --filter "id=$container_ref" --format "{{.Status}}" 2>/dev/null)
                if [ -z "$status" ]; then
                    status=$(docker ps -a --filter "name=$container_ref" --format "{{.Status}}" 2>/dev/null)
                fi
                
                if [ -z "$status" ]; then
                    print_error "Container not found: $container_ref"
                    return 1
                fi
                
                print_error "WARNING: This will force remove a container (even if running)"
                printf "Type 'FORCE REMOVE' to confirm: "
                read -r confirm
                if [ "$confirm" = "FORCE REMOVE" ]; then
                    if docker rm -f "$container_ref"; then
                        print_success "Container force removed successfully"
                    else
                        print_error "Failed to force remove container"
                        return 1
                    fi
                else
                    print_info "Operation cancelled"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                print_info "No action selected"
                return 0
                ;;
        esac
    fi
    
    return 0
}

# Function to delete docker images
delete_docker_images() {
    print_info "Docker Image Deletion Menu"
    printf "\n"
    
    # Check if docker is available
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker command not found"
        return 1
    fi
    
    # List images first
    if ! docker images; then
        print_error "Failed to list Docker images. Is Docker running?"
        return 1
    fi
    
    printf "\n"
    printf "Select deletion option:\n"
    printf "  1) Delete image by IMAGE ID\n"
    printf "  2) Delete image by REPOSITORY:TAG\n"
    printf "  3) Delete all unused images (prune)\n"
    printf "  4) Delete all <none>:<none> images\n"
    printf "  5) Delete all images (DANGEROUS)\n"
    printf "  0) Back to main menu\n"
    printf "\n"
    printf "Enter your choice: "
    read -r delete_choice
    
    case "$delete_choice" in
        1)
            printf "Enter IMAGE ID: "
            read -r image_id
            if [ -z "$image_id" ]; then
                print_error "IMAGE ID cannot be empty"
                return 1
            fi
            print_warning "About to delete image: $image_id"
            printf "Are you sure? (y/n): "
            read -r confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                print_info "Operation cancelled"
                return 0
            fi
            if docker rmi "$image_id"; then
                print_success "Image deleted successfully"
            else
                print_error "Failed to delete image. Try with -f flag? (y/n): "
                read -r force_choice
                if [ "$force_choice" = "y" ] || [ "$force_choice" = "Y" ]; then
                    docker rmi -f "$image_id"
                fi
            fi
            ;;
        2)
            printf "Enter REPOSITORY:TAG (e.g., nginx:latest): "
            read -r image_name
            if [ -z "$image_name" ]; then
                print_error "Image name cannot be empty"
                return 1
            fi
            print_warning "About to delete image: $image_name"
            printf "Are you sure? (y/n): "
            read -r confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                print_info "Operation cancelled"
                return 0
            fi
            if docker rmi "$image_name"; then
                print_success "Image deleted successfully"
            else
                print_error "Failed to delete image. Try with -f flag? (y/n): "
                read -r force_choice
                if [ "$force_choice" = "y" ] || [ "$force_choice" = "Y" ]; then
                    docker rmi -f "$image_name"
                fi
            fi
            ;;
        3)
            print_warning "This will delete all dangling images..."
            printf "Are you sure? (y/n): "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                docker image prune -f
                print_success "Unused images pruned"
            else
                print_info "Operation cancelled"
            fi
            ;;
        4)
            print_warning "This will delete all <none>:<none> images..."
            
            # Check if there are any <none> images
            none_images=$(docker images -f "dangling=true" -q 2>/dev/null)
            
            if [ -z "$none_images" ]; then
                print_info "No <none>:<none> images found"
                return 0
            fi
            
            # Show the images that will be deleted
            print_info "Images to be deleted:"
            docker images -f "dangling=true"
            printf "\n"
            
            printf "Are you sure? (y/n): "
            read -r confirm
            if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                # First, try to delete images normally (the easy ones)
                print_info "Attempting to delete images..."
                printf "\n"
                deleted_count=0
                failed_images=""
                
                for img_id in $none_images; do
                    if docker rmi "$img_id" 2>/dev/null; then
                        print_success "Deleted image: $img_id"
                        deleted_count=$((deleted_count + 1))
                    else
                        failed_images="$failed_images $img_id"
                    fi
                done
                
                printf "\n"
                if [ $deleted_count -gt 0 ]; then
                    print_success "Successfully deleted $deleted_count image(s)"
                fi
                
                # Handle stubborn images
                if [ -n "$failed_images" ]; then
                    failed_count=$(echo "$failed_images" | wc -w | tr -d ' ')
                    print_warning "$failed_count stubborn image(s) could not be deleted"
                    printf "\n"
                    
                    # Show details about stubborn images
                    print_info "Stubborn images:"
                    for img_id in $failed_images; do
                        docker images --filter "dangling=true" --format "table {{.ID}}\t{{.CreatedAt}}\t{{.Size}}" | grep "$img_id"
                        
                        # Check for containers
                        containers=$(docker ps -a -q --filter "ancestor=$img_id" 2>/dev/null)
                        if [ -n "$containers" ]; then
                            container_count=$(echo "$containers" | wc -l | tr -d ' ')
                            printf "  └─ Used by %s container(s)\n" "$container_count"
                        fi
                        
                        # Check for child images
                        children=$(docker images -a --format "{{.ID}} {{.ParentID}}" 2>/dev/null | grep "$img_id" | wc -l | tr -d ' ')
                        if [ "$children" -gt 0 ]; then
                            printf "  └─ Has %s child layer(s)\n" "$children"
                        fi
                    done
                    
                    printf "\n"
                    printf "Do you want to handle stubborn images? (y/n): "
                    read -r handle_stubborn
                    
                    if [ "$handle_stubborn" = "y" ] || [ "$handle_stubborn" = "Y" ]; then
                        # First offer to remove containers
                        print_info "Checking for containers..."
                        containers_exist=0
                        for img_id in $failed_images; do
                            containers=$(docker ps -a -q --filter "ancestor=$img_id" 2>/dev/null)
                            if [ -n "$containers" ]; then
                                containers_exist=1
                                break
                            fi
                        done
                        
                        if [ $containers_exist -eq 1 ]; then
                            printf "Remove associated containers? (y/n): "
                            read -r remove_containers
                            if [ "$remove_containers" = "y" ] || [ "$remove_containers" = "Y" ]; then
                                for img_id in $failed_images; do
                                    containers=$(docker ps -a -q --filter "ancestor=$img_id" 2>/dev/null)
                                    if [ -n "$containers" ]; then
                                        print_info "Removing containers for $img_id..."
                                        docker rm -f $containers 2>/dev/null
                                    fi
                                done
                                print_success "Containers removed"
                                printf "\n"
                                
                                # Try deleting again after removing containers
                                print_info "Retrying image deletion..."
                                new_failed=""
                                for img_id in $failed_images; do
                                    if docker rmi "$img_id" 2>/dev/null; then
                                        print_success "Deleted: $img_id"
                                    else
                                        new_failed="$new_failed $img_id"
                                    fi
                                done
                                failed_images="$new_failed"
                            fi
                        fi
                        
                        # If still have failed images, offer force delete
                        if [ -n "$failed_images" ]; then
                            printf "\nForce delete remaining stubborn images? (y/n): "
                            read -r force_choice
                            if [ "$force_choice" = "y" ] || [ "$force_choice" = "Y" ]; then
                                print_info "Force deleting..."
                                for img_id in $failed_images; do
                                    if docker rmi -f "$img_id" 2>/dev/null; then
                                        print_success "Force deleted: $img_id"
                                    else
                                        print_error "Failed even with force: $img_id"
                                    fi
                                done
                            else
                                print_info "Stubborn images kept"
                            fi
                        else
                            print_success "All images deleted after container removal!"
                        fi
                    else
                        print_info "Stubborn images kept"
                    fi
                else
                    print_success "All <none>:<none> images deleted successfully!"
                fi
            else
                print_info "Operation cancelled"
            fi
            ;;
        5)
            print_error "WARNING: This will delete ALL Docker images!"
            printf "Type 'DELETE ALL' to confirm: "
            read -r confirm
            if [ "$confirm" = "DELETE ALL" ]; then
                docker rmi -f $(docker images -q) 2>/dev/null
                print_success "All images deleted"
            else
                print_info "Operation cancelled"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            print_error "Invalid choice"
            return 1
            ;;
    esac
    
    return 0
}

# Function to start interactive shell in a container
interactive_shell() {
    print_info "Interactive Shell - Select Docker Image"
    printf "\n"
    
    # Check if docker is available
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker command not found"
        return 1
    fi
    
    # Get list of images with numbering
    print_info "Available Docker images:"
    printf "\n"
    
    # Store images in a temporary way that's POSIX compatible
    # We'll use docker images with a specific format
    image_list=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null)
    
    if [ -z "$image_list" ]; then
        print_error "No Docker images found"
        return 1
    fi
    
    # Display images with numbers
    count=1
    printf "%s\n" "$image_list" | while IFS= read -r image; do
        printf "  %d) %s\n" "$count" "$image"
        count=$((count + 1))
    done
    
    printf "  0) Back to main menu\n"
    printf "\n"
    printf "Enter image number: "
    read -r selection
    
    # Handle back to menu
    if [ "$selection" = "0" ]; then
        return 0
    fi
    
    # Validate selection is a number
    if ! printf "%s" "$selection" | grep -qE '^[0-9]+$'; then
        print_error "Invalid selection. Please enter a number."
        return 1
    fi
    
    # Get the selected image
    selected_image=$(printf "%s\n" "$image_list" | sed -n "${selection}p")
    
    if [ -z "$selected_image" ]; then
        print_error "Invalid selection"
        return 1
    fi
    
    print_info "Starting interactive shell for image: $selected_image"
    printf "\n"
    print_warning "You will be placed in a bash shell inside the container."
    print_info "Type 'exit' to return to this menu."
    printf "\n"
    printf "Press Enter to continue..."
    read -r dummy
    
    # Try to start with /bin/bash, fallback to /bin/sh if bash is not available
    if ! docker run -it --rm "$selected_image" /bin/bash 2>/dev/null; then
        print_warning "Bash not available, trying /bin/sh..."
        if ! docker run -it --rm "$selected_image" /bin/sh; then
            print_error "Failed to start interactive shell"
            return 1
        fi
    fi
    
    print_success "Shell session ended"
    return 0
}

# Function to display menu
show_menu() {
    printf "\n"
    printf "========================================\n"
    printf "   Docker Management Script\n"
    printf "========================================\n"
    if [ "$OS" = "macos" ]; then
        printf "  0) Check/Start Colima (macOS)\n"
    else
        printf "  0) Check Docker Status\n"
    fi
    printf "  1) List Docker Images\n"
    printf "  2) List Docker Processes\n"
    printf "  3) Delete Docker Images\n"
    printf "  4) Interactive Shell\n"
    printf "  q) Quit\n"
    printf "========================================\n"
    printf "Enter your choice: "
}

# Main loop
main() {
    # Check if running in interactive terminal
    if [ ! -t 0 ]; then
        print_error "This script requires an interactive terminal"
        exit 1
    fi
    
    # Detect OS at startup
    detect_os
    
    while true; do
        show_menu
        read -r choice
        
        case "$choice" in
            0)
                check_and_start_colima
                printf "\nPress Enter to continue..."
                read -r dummy
                ;;
            1)
                list_docker_images
                printf "\nPress Enter to continue..."
                read -r dummy
                ;;
            2)
                list_docker_processes
                printf "\nPress Enter to continue..."
                read -r dummy
                ;;
            3)
                delete_docker_images
                printf "\nPress Enter to continue..."
                read -r dummy
                ;;
            4)
                interactive_shell
                printf "\nPress Enter to continue..."
                read -r dummy
                ;;
            q|Q)
                print_info "Exiting..."
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please try again."
                printf "\nPress Enter to continue..."
                read -r dummy
                ;;
        esac
    done
}

# Run main function
main
