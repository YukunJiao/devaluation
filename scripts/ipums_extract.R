#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)
command <- if (length(args) >= 1) args[[1]] else "help"

request_path <- "data/ipums/metadata/ipums_usa_1850_1880_extract_request.json"
status_path <- "data/ipums/metadata/ipums_usa_1850_1880_extract_status.json"
download_dir <- "data/ipums/raw"
base_url <- "https://api.ipums.org/extracts"
collection <- "usa"
version <- "2"

need_packages <- function() {
  for (pkg in c("httr2", "jsonlite")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("Package not installed: ", pkg, call. = FALSE)
    }
  }
}

api_key <- function() {
  key <- Sys.getenv("IPUMS_API_KEY")
  if (!nzchar(key)) {
    stop("Add your IPUMS token to .Renviron as IPUMS_API_KEY=...", call. = FALSE)
  }
  key
}

endpoint <- function(number = NULL) {
  url <- base_url
  if (!is.null(number)) {
    url <- paste0(url, "/", number)
  }
  paste0(url, "?collection=", collection, "&version=", version)
}

write_json <- function(data, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(data, path, auto_unbox = TRUE, pretty = TRUE)
}

submit_extract <- function() {
  need_packages()
  payload <- jsonlite::read_json(request_path, simplifyVector = FALSE)
  response <- httr2::request(endpoint()) |>
    httr2::req_headers(
      Authorization = api_key(),
      "Content-Type" = "application/json"
    ) |>
    httr2::req_body_json(payload, auto_unbox = TRUE) |>
    httr2::req_perform()

  status <- httr2::resp_body_json(response, simplifyVector = FALSE)
  write_json(status, status_path)
  cat("Submitted extract", status$number, "with status", status$status, "\n")
}

read_extract_number <- function() {
  if (length(args) >= 2) {
    return(args[[2]])
  }
  if (!file.exists(status_path)) {
    stop("No status file found. Run: Rscript scripts/ipums_extract.R submit", call. = FALSE)
  }
  status <- jsonlite::read_json(status_path, simplifyVector = FALSE)
  if (is.null(status$number)) {
    stop("Status file does not include an extract number.", call. = FALSE)
  }
  as.character(status$number)
}

check_status <- function() {
  need_packages()
  number <- read_extract_number()
  response <- httr2::request(endpoint(number)) |>
    httr2::req_headers(
      Authorization = api_key(),
      "Content-Type" = "application/json"
    ) |>
    httr2::req_perform()

  status <- httr2::resp_body_json(response, simplifyVector = FALSE)
  write_json(status, status_path)
  cat("Extract", status$number, "status:", status$status, "\n")
}

download_file <- function(url, path) {
  response <- httr2::request(url) |>
    httr2::req_headers(Authorization = api_key()) |>
    httr2::req_perform()
  writeBin(httr2::resp_body_raw(response), path)
}

download_extract <- function() {
  need_packages()
  if (!file.exists(status_path)) {
    check_status()
  }
  status <- jsonlite::read_json(status_path, simplifyVector = FALSE)
  links <- status$downloadLinks
  if (is.null(links) || is.null(links$data$url)) {
    stop("No data download link yet. Run status again after IPUMS completes the extract.", call. = FALSE)
  }

  dir.create(download_dir, recursive = TRUE, showWarnings = FALSE)
  data_name <- basename(links$data$url)
  download_file(links$data$url, file.path(download_dir, data_name))

  if (!is.null(links$basicCodebook$url)) {
    download_file(links$basicCodebook$url, file.path(download_dir, basename(links$basicCodebook$url)))
  }
  if (!is.null(links$rCommandFile$url)) {
    download_file(links$rCommandFile$url, file.path(download_dir, basename(links$rCommandFile$url)))
  }
  cat("Downloaded extract files to", download_dir, "\n")
}

if (command == "submit") {
  submit_extract()
} else if (command == "status") {
  check_status()
} else if (command == "download") {
  download_extract()
} else {
  cat("Usage:\n")
  cat("  Rscript scripts/ipums_extract.R submit\n")
  cat("  Rscript scripts/ipums_extract.R status [extract_number]\n")
  cat("  Rscript scripts/ipums_extract.R download\n")
}
