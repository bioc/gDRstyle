setReposOpt <- function(additionalRepos = NULL) {
  repos <- c(
    CRAN = "https://cran.microsoft.com/snapshot/2021-08-25",
    additionalRepos
  )
  options(repos = repos)
}

setTokenVar <- function(base_dir) {
  # Use GitHub access_token if available
  gh_access_token_file <- file.path(base_dir, ".github_access_token.txt")
  if (file.exists(gh_access_token_file)) {
    secrets <- readLines(gh_access_token_file)
    stopifnot(length(secrets) > 0)

    if(length(secrets) == 1) {
      Sys.setenv(GITHUB_PAT = secrets)
    } else {
      tokens <- strsplit(secrets, "=")
      lapply(tokens, function(x) {
        args <- list(x[2])
        names(args) <- x[1]

        do.call(Sys.setenv, args)
      })
    }
  }
}

# Auxiliary functions
verify_version <- function(name, required_version) {
  pkg_version <- packageVersion(name)
  ## '>=1.2.3' => '>= 1.2.3'
  required_version <-
    gsub("^([><=]+)([0-9.]+)$", "\\1 \\2", required_version, perl = TRUE)
  if (!remotes:::version_satisfies_criteria(pkg_version, required_version)) {
    stop(sprintf(
      "Invalid version of %s. Installed: %s, required %s.",
      name,
      pkg_version,
      required_version
    ))
  }
}
#' this function help figuring out which GitHub domain should be used
#' github.roche.com will be chosen if available
#' otherwise github.com
get_github_hostname <- function() {
  conn_status <- tryCatch(
    curl::curl_fetch_memory("github.roche.com"),
    error = function(e) {
      e
    }
  )
  # error in connection to database will be returned as error list with exit_code = 2
  if (inherits(conn_status, "error")) {
    "api.github.com"
  } else {
    "github.roche.com/api/v3"
  }
}

getSshKeys <- function(use_ssh) {
  if (isTRUE(use_ssh)) {
    git2r::cred_ssh_key(
      publickey = ssh_key_pub,
      privatekey = ssh_key_priv
    )
  }
}

#' Install locally cloned repo for builiding image purposes
#'
#' @param repo_path String of repository directory.
#' @param base_dir String of base working directory.
#'
#' @export
installLocalPackage <- function(repo_path, additionalRepos = NULL, base_dir = "/mnt/vol") {
  setReposOpt(additionalRepos)
  setTokenVar(base_dir)

  remotes::install_local(path = repo_path)
}

#' Install all package dependencies from yaml file for builiding image purposes
#'
#' @param base_dir String of base working directory.
#' @param use_ssh logical, if use ssh keys
#'
#' @export
installAllDeps <- function(additionalRepos = NULL, base_dir = "/mnt/vol", use_ssh = FALSE) {
  setReposOpt(additionalRepos)
  setTokenVar(base_dir)
  gh_hostname <- get_github_hostname()
  keys <- getSshKeys(use_ssh)

  deps_yaml <- file.path(base_dir, "/dependencies.yaml")
  deps <- yaml::read_yaml(deps_yaml)$pkgs

  for (name in names(deps)) {
    pkg <- deps[[name]]
    if (is.null(pkg$source)) {
      pkg$source <- "Git" 
    }
    switch(
      EXPR = toupper(pkg$source),

      ## CRAN installation
      "CRAN" = {
        if (is.null(pkg$repos)) {
          pkg$repos <- getOption("repos")
        }
        remotes::install_version(
          package = name,
          version = pkg$ver,
          repos = pkg$repos
        )
      },

      ## Bioconductor installation
      "BIOC" = {
        if (is.null(pkg$ver)) {
          pkg$ver <- BiocManager::version() 
        }
        BiocManager::install(
          pkgs = name,
          update = FALSE,
          version = pkg$ver  ## Bioc version or 'devel'
        )
      },

      ## GitHub installation
      "GITHUB" = {
        if (is.null(pkg$ref)) {
          pkg$ref <- "HEAD" 
        }
        remotes::install_github(
          repo = pkg$url,
          ref = pkg$ref,
          subdir = pkg$subdir,
          host = ifelse(!is.null(pkg$host), pkg$host, gh_hostname)
        )
        verify_version(name, pkg$ver)
      },

      ## Git installation
      "GIT" = {
        remotes::install_git(
          url = pkg$url,
          subdir = pkg$subdir,
          ref = pkg$ref,
          credentials = keys
        )
        verify_version(name, pkg$ver)
      },

      "GITLAB" = {
        remotes::install_gitlab(
          repo = pkg$repo,
          host = ifelse(!is.null(pkg$host), pkg$host, "code.roche.com"),
          subdir = pkg$subdir,
          ref = pkg$ref
        )
        verify_version(name, pkg$ver)
      },

      stop("Invalid or unsupported source attribute")
    )
  }
}