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

variable "xcode_version" {
  type = list(string)
}

variable "additional_ios_builds" {
  type    = list(string)
  default = []
}

variable "additional_tvos_builds" {
  type    = list(string)
  default = []
}

variable "xcode_components" {
  type        = list(string)
  default     = []
  description = "Additional Xcode components to download."
}

variable "expected_runtimes_file" {
  type        = string
  default     = ""
  description = "Path to file containing expected simulator runtimes. If empty, runtime verification is skipped."
}

variable "disk_size" {
  type    = number
  default = 140
}

variable "disk_free_mb" {
  type    = number
  default = 15000
}

source "tart-cli" "tart" {
  // The workflow sizes the VM before boot; only the guest daemon resizes APFS.
  recovery_partition = "keep"
  vm_name            = var.vm_name
  cpu_count          = 4
  memory_gb          = 8
  headless           = true
  ssh_password       = "admin"
  ssh_username       = "admin"
  ssh_timeout        = "120s"
}

locals {
  xcode_install_provisioners = [
    for version in reverse(sort(var.xcode_version)) : {
      inline = [
        "source ~/.zprofile",
        "sudo xcodes install ${version} --experimental-unxip --path /Users/admin/Downloads/Xcode_${version}.xip --select --empty-trash",
        // get selected xcode path, strip /Contents/Developer and move to GitHub compatible locations
        "INSTALLED_PATH=$(xcodes select -p)",
        "CONTENTS_DIR=$(dirname $INSTALLED_PATH)",
        "APP_DIR=$(dirname $CONTENTS_DIR)",
        "sudo mv $APP_DIR /Applications/Xcode_${version}.app",
        "sudo xcode-select -s /Applications/Xcode_${version}.app",
        "xcodebuild -downloadPlatform iOS",
        "xcodebuild -runFirstLaunch",
        "df -h",
      ]
    }
  ]
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    // Allow 6 GB for boot/recovery partitions and metadata; Tart uses decimal GB.
    inline = [
      "minimum_kb=${floor((var.disk_size - 6) * 1000000000 / 1024)}",
      "for ((attempt = 0; attempt < 60; attempt++)); do",
      "  size_kb=$(df -k /System/Volumes/Data | awk 'NR == 2 {print $2}')",
      "  [[ $size_kb -ge $minimum_kb ]] && break",
      "  sleep 2",
      "done",
      "[[ $size_kb -ge $minimum_kb ]] || { echo 'APFS did not expand to ${var.disk_size} GB within 120 seconds.' >&2; exit 1; }",
      "source ~/.zprofile",
      "brew install xcodes",
      "brew cleanup",
      "xcodes version",
    ]
  }

  provisioner "file" {
    sources     = [for version in var.xcode_version : "/tmp/Xcode_${version}.xip"]
    destination = "/Users/admin/Downloads/"
  }

  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "df -h",
    ]
  }

  // iterate over all Xcode versions and install them
  // select the latest one as the default
  dynamic "provisioner" {
    for_each = local.xcode_install_provisioners
    labels   = ["shell"]
    content {
      inline = provisioner.value.inline
    }
  }

  dynamic "provisioner" {
    for_each = length(var.xcode_version) > 2 ? [2] : []
    labels   = ["shell"]
    content {
      inline = [
        "source ~/.zprofile",
        "sudo xcode-select -s /Applications/Xcode_${var.xcode_version[2]}.app/Contents/Developer",
        "xcodebuild -downloadAllPlatforms",
      ]
    }
  }

  dynamic "provisioner" {
    for_each = length(var.xcode_version) > 1 ? [1] : []
    labels   = ["shell"]
    content {
      inline = [
        "source ~/.zprofile",
        "sudo xcode-select -s /Applications/Xcode_${var.xcode_version[1]}.app/Contents/Developer",
        "xcodebuild -downloadAllPlatforms",
      ]
    }
  }

  // Download legacy iOS runtimes before selecting the newest Xcode.
  provisioner "shell" {
    inline = concat(
      ["source ~/.zprofile"],
      [
        for runtime in var.additional_ios_builds : "xcodebuild -downloadPlatform iOS -buildVersion ${runtime}"
      ]
    )
  }

  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "sudo xcode-select -s /Applications/Xcode_${var.xcode_version[0]}.app/Contents/Developer",
      "xcodebuild -downloadAllPlatforms",
    ]
  }

  provisioner "shell" {
    inline = concat(
      ["source ~/.zprofile"],
      [
        for runtime in var.additional_tvos_builds : "xcodebuild -downloadPlatform tvOS -buildVersion ${runtime}"
      ]
    )
  }

  provisioner "shell" {
    inline = concat(
      ["source ~/.zprofile"],
      [
        for component in var.xcode_components : "xcodebuild -downloadComponent ${component}"
      ]
    )
  }

  // Copy expected runtimes file if provided
  dynamic "provisioner" {
    for_each = var.expected_runtimes_file != "" ? [1] : []
    labels   = ["file"]
    content {
      source      = var.expected_runtimes_file
      destination = "/Users/admin/runtimes.expected.txt"
    }
  }

  // Verify simulator runtimes match expected list if file was provided
  dynamic "provisioner" {
    for_each = var.expected_runtimes_file != "" ? [1] : []
    labels   = ["shell"]
    content {
      inline = [
        "source ~/.zprofile",
        "xcrun simctl list runtimes > /Users/admin/runtimes.actual.txt",
        "diff -q /Users/admin/runtimes.actual.txt /Users/admin/runtimes.expected.txt || (echo 'Simulator runtimes do not match expected list' && cat /Users/admin/runtimes.actual.txt && exit 1)",
        "rm /Users/admin/runtimes.actual.txt /Users/admin/runtimes.expected.txt"
      ]
    }
  }

  # inspired by https://github.com/actions/runner-images/blob/fb3b6fd69957772c1596848e2daaec69eabca1bb/images/macos/provision/configuration/configure-machine.sh#L33-L61
  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "curl -o AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer",
      "curl -o DeveloperIDG2CA.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer",
      "curl -o add-certificate.swift https://raw.githubusercontent.com/actions/runner-images/fb3b6fd69957772c1596848e2daaec69eabca1bb/images/macos/provision/configuration/add-certificate.swift",
      "swiftc -suppress-warnings add-certificate.swift",
      "sudo ./add-certificate AppleWWDRCAG3.cer",
      "sudo ./add-certificate DeveloperIDG2CA.cer",
      "rm add-certificate* *.cer"
    ]
  }

  // check there is at least 15GB of free space and fail if not
  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "df -h",
      "export FREE_MB=$(df -m | awk '{print $4}' | head -n 2 | tail -n 1)",
      "[[ $FREE_MB -gt ${var.disk_free_mb} ]] && echo OK || exit 1"
    ]
  }

  # Disable apsd[1][2] daemon as it causes high CPU usage after boot
  #
  # [1]: https://iboysoft.com/wiki/apsd-mac.html
  # [2]: https://discussions.apple.com/thread/4459153
  provisioner "shell" {
    inline = [
      "sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.apsd.plist"
    ]
  }

  # Wait for the "update_dyld_sim_shared_cache" process[1][2] to finish
  # to avoid wasting CPU cycles after boot
  #
  # [1]: https://apple.stackexchange.com/questions/412101/update-dyld-sim-shared-cache-is-taking-up-a-lot-of-memory
  # [2]: https://stackoverflow.com/a/68394101/9316533
  provisioner "shell" {
    inline = [
      "source ~/.zprofile",
      "xcrun simctl runtime dyld_shared_cache update --all || sleep 180",
      "xcrun simctl list -v"
    ]
  }
}
