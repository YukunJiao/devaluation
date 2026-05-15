analysis_years <- c(1850L, 1860L, 1870L, 1880L)

empty_ipums <- function() {
  tibble::tibble(
    year = integer(),
    sample = character(),
    serial = character(),
    pernum = character(),
    perwt = numeric(),
    age = numeric(),
    sex = character(),
    race = character(),
    statefip = character(),
    occ = character(),
    occ1950 = character(),
    occstr = character()
  )
}

empty_kwic <- function() {
  tibble::tibble(
    year = integer(),
    date = character(),
    newspaper_name = character(),
    article_id = character(),
    keyword = character(),
    context = character()
  )
}

list_ipums_files <- function(path = "data/ipums") {
  if (!dir.exists(path)) {
    return(character())
  }
  files <- list.files(path, pattern = "\\.csv(\\.gz)?$", recursive = TRUE, full.names = TRUE)
  files[!grepl("metadata|summary|derived", files, ignore.case = TRUE)]
}

list_kwic_files <- function(path = "data/kwic") {
  if (!dir.exists(path)) {
    return(character())
  }
  list.files(path, pattern = "\\.csv$", recursive = TRUE, full.names = TRUE)
}

clean_names <- function(data) {
  names(data) <- tolower(names(data))
  data
}

read_csv_base <- function(path) {
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

first_present <- function(data, candidates, default = NA) {
  found <- candidates[candidates %in% names(data)]
  if (length(found) == 0) {
    return(rep(default, nrow(data)))
  }
  data[[found[1]]]
}

read_ipums_microdata <- function(files) {
  if (length(files) == 0) {
    return(empty_ipums())
  }

  rows <- lapply(files, function(path) {
    data <- clean_names(read_csv_base(path))
    tibble::tibble(
      year = suppressWarnings(as.integer(first_present(data, "year"))),
      sample = as.character(first_present(data, "sample")),
      serial = as.character(first_present(data, "serial")),
      pernum = as.character(first_present(data, "pernum")),
      perwt = suppressWarnings(as.numeric(first_present(data, "perwt", 1))),
      age = suppressWarnings(as.numeric(first_present(data, "age"))),
      sex = as.character(first_present(data, "sex")),
      race = as.character(first_present(data, "race")),
      statefip = as.character(first_present(data, "statefip")),
      occ = as.character(first_present(data, "occ")),
      occ1950 = as.character(first_present(data, "occ1950")),
      occstr = as.character(first_present(data, "occstr"))
    )
  })

  dplyr::bind_rows(rows) |>
    dplyr::filter(.data$year %in% analysis_years) |>
    dplyr::mutate(
      perwt = dplyr::if_else(is.na(.data$perwt), 1, .data$perwt),
      sex_label = dplyr::case_when(
        .data$sex %in% c("1", "Male", "MALE") ~ "male",
        .data$sex %in% c("2", "Female", "FEMALE") ~ "female",
        TRUE ~ "unknown"
      )
    )
}

read_kwic_data <- function(files) {
  if (length(files) == 0) {
    return(empty_kwic())
  }

  rows <- lapply(files, function(path) {
    data <- clean_names(read_csv_base(path))
    tibble::tibble(
      year = suppressWarnings(as.integer(first_present(data, "year"))),
      date = as.character(first_present(data, "date")),
      newspaper_name = as.character(first_present(data, "newspaper_name")),
      article_id = as.character(first_present(data, "article_id")),
      keyword = as.character(first_present(data, "keyword")),
      context = as.character(first_present(data, "context"))
    )
  })

  dplyr::bind_rows(rows) |>
    dplyr::filter(.data$year %in% analysis_years)
}

summarize_ipums_occupations <- function(ipums) {
  if (nrow(ipums) == 0) {
    return(tibble::tibble())
  }

  ipums |>
    dplyr::filter(!is.na(.data$occ1950), .data$occ1950 != "", .data$occ1950 != "0") |>
    dplyr::group_by(.data$year, .data$occ1950, .data$occstr) |>
    dplyr::summarise(
      records = dplyr::n(),
      workers = sum(.data$perwt, na.rm = TRUE),
      female_workers = sum(.data$perwt[.data$sex_label == "female"], na.rm = TRUE),
      female_share = dplyr::if_else(
        sum(.data$perwt, na.rm = TRUE) > 0,
        sum(.data$perwt[.data$sex_label == "female"], na.rm = TRUE) / sum(.data$perwt, na.rm = TRUE),
        NA_real_
      ),
      median_age = stats::median(.data$age, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::arrange(.data$year, dplyr::desc(.data$workers))
}

summarize_kwic_mentions <- function(kwic) {
  if (nrow(kwic) == 0) {
    return(tibble::tibble())
  }

  kwic |>
    dplyr::filter(!is.na(.data$keyword), .data$keyword != "") |>
    dplyr::group_by(.data$year, .data$keyword) |>
    dplyr::summarise(
      mentions = dplyr::n(),
      articles = dplyr::n_distinct(.data$article_id),
      newspapers = dplyr::n_distinct(.data$newspaper_name),
      .groups = "drop"
    ) |>
    dplyr::arrange(.data$year, dplyr::desc(.data$mentions))
}

bridge_kwic_to_ipums <- function(kwic_mentions, ipums_occupations) {
  if (nrow(kwic_mentions) == 0 || nrow(ipums_occupations) == 0) {
    return(tibble::tibble())
  }

  keywords <- unique(kwic_mentions$keyword)
  rows <- lapply(keywords, function(keyword) {
    matches <- grepl(keyword, ipums_occupations$occstr, ignore.case = TRUE, fixed = TRUE)
    if (!any(matches, na.rm = TRUE)) {
      return(NULL)
    }
    ipums_occupations[matches, , drop = FALSE] |>
      dplyr::mutate(keyword = keyword)
  })

  occupation_matches <- dplyr::bind_rows(rows)
  if (nrow(occupation_matches) == 0) {
    return(tibble::tibble())
  }

  dplyr::full_join(
    kwic_mentions,
    occupation_matches,
    by = c("year", "keyword")
  ) |>
    dplyr::arrange(.data$keyword, .data$year, dplyr::desc(.data$workers))
}
