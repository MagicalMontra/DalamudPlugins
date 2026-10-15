# MagicalMontra combined Dalamud feed

Custom repository URL: https://raw.githubusercontent.com/MagicalMontra/DalamudPlugins/main/repo.json

Contains Vendor Runner and the custom Wahventory fork. Release ZIPs are hosted in this repository.

For future versions, run Publish-DalamudPlugins.ps1 -PackagePath <compiled-plugin.zip> -Publish. The publisher merges the updated entry and preserves the other plugin. Bump the assembly version for changed binaries.

No-argument migration reads the old feeds; it is for initial setup, not a scheduled update service. After retiring the old feed-only repository, publish new packages directly here.

Keep the source repositories: MagicalMontra/VendorRunner and https://github.com/MagicalMontra/wahventory . No automatic source merge, repository deletion or visibility change is performed.

When changing a third-party source URL in Dalamud, reinstall from the new source while retaining plugin configuration.
