https://__GITEA_HOST__ {
  tls internal
  encode zstd gzip
  reverse_proxy gitea:3000
}

__WORKSPACE_ROUTES__
