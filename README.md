# LeoCastra public installer

Public bootstrap for private **leocastra-cloud-studio**. See [deploy/PRIVATE-GITHUB-INSTALL.md](https://github.com/pimccontent/leocastra-cloud-studio/blob/main/deploy/PRIVATE-GITHUB-INSTALL.md).

```bash
export GITHUB_TOKEN="ghp_xxxx"
curl -fsSL https://raw.githubusercontent.com/pimccontent/leocastra-install/main/install.sh |
  sudo -E bash -s -- --domain studio.example.com --email you@example.com --github-token "$GITHUB_TOKEN"
```
