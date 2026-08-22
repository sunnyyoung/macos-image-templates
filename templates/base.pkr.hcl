packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type = string
}

source "tart-cli" "tart" {
  vm_name      = "${var.vm_name}"
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 50
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "120s"
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "file" {
    source      = "data/limit.maxfiles.plist"
    destination = "~/limit.maxfiles.plist"
  }

  provisioner "shell" {
    inline = [
      "echo 'Configuring maxfiles...'",
      "sudo mv ~/limit.maxfiles.plist /Library/LaunchDaemons/limit.maxfiles.plist",
      "sudo chown root:wheel /Library/LaunchDaemons/limit.maxfiles.plist",
      "sudo chmod 0644 /Library/LaunchDaemons/limit.maxfiles.plist",
      "echo 'Disabling spotlight...'",
      "sudo mdutil -a -i off",
    ]
  }

  # Create a symlink for bash compatibility
  provisioner "shell" {
    inline = [
      "touch ~/.zprofile",
      "ln -s ~/.zprofile ~/.profile",
    ]
  }

  provisioner "shell" {
    inline = [
      "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
      "echo \"export LANG=en_US.UTF-8\" >> ~/.zprofile",
      "echo \"export LANGUAGE=en_US.UTF-8\" >> ~/.zprofile",
      "echo \"export LC_ALL=en_US.UTF-8\" >> ~/.zprofile",
      "echo \"export HOMEBREW_NO_ANALYTICS=1\" >> ~/.zprofile",
      "echo \"export HOMEBREW_NO_ENV_HINTS=1\" >> ~/.zprofile",
      "echo \"export HOMEBREW_CLEANUP_MAX_AGE_DAYS=0\" >> ~/.zprofile",
      "echo 'eval \"$(/opt/homebrew/bin/brew shellenv)\"' >> ~/.zprofile",
    ]
  }

  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "brew --version",
      "brew update",
      "brew install ca-certificates cmake create-dmg gcc gitlab-runner libyaml mise nodenv pyenv rbenv wget",
      "brew cleanup",
      "git config --global credential.helper ''",
      "sudo softwareupdate --install-rosetta --agree-to-license"
    ]
  }

  // Add GitHub to known hosts
  // Similar to https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-ssh.sh
  provisioner "shell" {
    inline = [
      "mkdir -p ~/.ssh"
    ]
  }
  provisioner "shell" {
    inline = [
      <<-EOF
      cat > ~/.ssh/config <<'SSH_CONFIG'
      Host *
        ServerAliveInterval 60
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        NoHostAuthenticationForLocalhost yes
      SSH_CONFIG
      chmod 600 ~/.ssh/config
      EOF
    ]
  }
  provisioner "shell" {
    inline = [
      "sudo safaridriver --enable",
    ]
  }

  # Enable UI automation, see https://github.com/cirruslabs/macos-image-templates/issues/136
  provisioner "shell" {
    script = "scripts/automationmodetool.expect"
  }

  // Install the process-scoped Metal shim for opt-in workloads.
  provisioner "shell" {
    inline = ["mkdir -p ~/tart-metal-capabilities-src"]
  }
  provisioner "file" {
    source      = "data/tart-metal-capabilities/"
    destination = "~/tart-metal-capabilities-src/"
  }
  provisioner "shell" {
    environment_vars = ["TART_METAL_SOURCE_DIR=/Users/admin/tart-metal-capabilities-src"]
    script           = "scripts/install-tart-metal-capabilities.sh"
  }
  provisioner "shell" {
    inline = ["rm -rf ~/tart-metal-capabilities-src"]
  }

  // Guest agent for Tart VMs
  provisioner "file" {
    source      = "data/tart-guest-daemon.plist"
    destination = "~/tart-guest-daemon.plist"
  }
  provisioner "file" {
    source      = "data/tart-guest-agent.plist"
    destination = "~/tart-guest-agent.plist"
  }
  provisioner "shell" {
    inline = [
      # Install Tart Guest Agent
      "source ~/.zprofile",
      "brew install openai/tools/tart-guest-agent",
      "brew cleanup",

      # Install daemon variant of the Tart Guest Agent
      "sudo mv ~/tart-guest-daemon.plist /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist",
      "sudo chown root:wheel /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist",
      "sudo chmod 0644 /Library/LaunchDaemons/org.cirruslabs.tart-guest-daemon.plist",

      # Install agent variant of the Tart Guest Agent
      "sudo mv ~/tart-guest-agent.plist /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist",
      "sudo chown root:wheel /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist",
      "sudo chmod 0644 /Library/LaunchAgents/org.cirruslabs.tart-guest-agent.plist",
    ]
  }

  # Update TCC.db and allow automation tools
  provisioner "shell" {
    script = "scripts/update-tcc-database.sh"
  }
}
