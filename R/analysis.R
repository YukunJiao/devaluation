americanstories_years <- c(1850L, 1860L, 1870L, 1880L, 1890L, 1900L)
ipums_years <- c(1850L, 1860L, 1870L, 1880L)
python_bin <- Sys.getenv("PYTHON", "python")

run_external <- function(command, args) {
  status <- system2(command, args = args)
  if (!identical(status, 0L)) {
    stop("External command failed: ", command, " ", paste(args, collapse = " "), call. = FALSE)
  }
}

run_ipums_manifest <- function(
    script = "scripts/ipums_extract.py",
    manifest = "data/ipums/metadata/ipums_usa_1850_1880_manifest.json") {
  run_external(python_bin, c(script, "manifest"))
  manifest
}

run_ipums_ensure <- function(
    script = "scripts/ipums_extract.py",
    manifest = "data/ipums/metadata/ipums_usa_1850_1880_manifest.json",
    wait = FALSE) {
  args <- c(script, "ensure")
  if (wait) {
    args <- c(args, "--wait")
  }
  run_external(python_bin, args)
  manifest
}

prepare_ipums_data <- function(
    download = identical(tolower(Sys.getenv("DOWNLOAD_IPUMS", "false")), "true"),
    wait = identical(tolower(Sys.getenv("WAIT_IPUMS", "false")), "true")) {
  if (download) {
    return(run_ipums_ensure(wait = wait))
  }
  run_ipums_manifest()
}

run_americanstories_kwic <- function(
    script = "scripts/americanstories_kwic.py",
    terms_file = "data/kwic_terms_example.txt",
    out = "data/kwic/americanstories_1850_1900_kwic.csv",
    cache_dir = "data/raw/americanstories",
    years = americanstories_years,
    window = 50,
    max_articles_per_year = as.integer(Sys.getenv("AMSTORIES_MAX_ARTICLES_PER_YEAR", "5000")),
    max_rows_per_year_term = 1000) {
  args <- c(
    script,
    "--years",
    as.character(years),
    "--terms-file",
    terms_file,
    "--window",
    as.character(window),
    "--cache-dir",
    cache_dir,
    "--keep-archives",
    "--max-articles-per-year",
    as.character(max_articles_per_year),
    "--max-rows-per-year-term",
    as.character(max_rows_per_year_term),
    "--out",
    out
  )
  run_external(python_bin, args)
  out
}

run_glove_subset <- function(
    script = "scripts/subset_glove.py",
    kwic_file = "data/kwic/americanstories_1850_1900_kwic.csv",
    glove_file = "gloVe/glove_vectors_enwiki.txt",
    out = "data/embeddings/americanstories_glove_vocab.csv") {
  if (!file.exists(glove_file)) {
    stop("GloVe model file not found: ", glove_file, call. = FALSE)
  }
  args <- c(
    script,
    "--kwic",
    kwic_file,
    "--glove",
    glove_file,
    "--out",
    out
  )
  run_external(python_bin, args)
  out
}

read_terms_file <- function(path) {
  lines <- readLines(path, warn = FALSE)
  lines <- trimws(lines)
  lines[nzchar(lines) & !grepl("^#", lines)]
}

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
  names(data) <- tolower(gsub('^"|"$', "", names(data)))
  data
}

read_kwic_csv <- function(path) {
  utils::read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    quote = "\"",
    comment.char = "",
    fill = TRUE
  )
}

read_ipums_csv <- function(path) {
  utils::read.csv(
    path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    quote = "",
    comment.char = ""
  )
}

clean_text <- function(x) {
  trimws(gsub('^"|"$', "", as.character(x)))
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
    data <- clean_names(read_ipums_csv(path))
    tibble::tibble(
      year = suppressWarnings(as.integer(first_present(data, "year"))),
      sample = clean_text(first_present(data, "sample")),
      serial = clean_text(first_present(data, "serial")),
      pernum = clean_text(first_present(data, "pernum")),
      perwt = suppressWarnings(as.numeric(first_present(data, "perwt", 1))),
      age = suppressWarnings(as.numeric(first_present(data, "age"))),
      sex = clean_text(first_present(data, "sex")),
      race = clean_text(first_present(data, "race")),
      statefip = clean_text(first_present(data, "statefip")),
      occ = clean_text(first_present(data, "occ")),
      occ1950 = clean_text(first_present(data, "occ1950")),
      occstr = clean_text(first_present(data, "occstr"))
    )
  })

  dplyr::bind_rows(rows) |>
    dplyr::filter(.data$year %in% ipums_years) |>
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
    data <- clean_names(read_kwic_csv(path))
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
    dplyr::filter(.data$year %in% americanstories_years)
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

summarize_term_coverage <- function(terms, kwic_mentions) {
  grid <- expand.grid(
    keyword = terms,
    year = americanstories_years,
    stringsAsFactors = FALSE
  )

  if (nrow(kwic_mentions) == 0) {
    mentions <- tibble::tibble(
      year = integer(),
      keyword = character(),
      mentions = integer(),
      articles = integer(),
      newspapers = integer()
    )
  } else {
    mentions <- kwic_mentions
  }

  dplyr::left_join(grid, mentions, by = c("year", "keyword")) |>
    dplyr::mutate(
      mentions = dplyr::if_else(is.na(.data$mentions), 0L, .data$mentions),
      articles = dplyr::if_else(is.na(.data$articles), 0L, .data$articles),
      newspapers = dplyr::if_else(is.na(.data$newspapers), 0L, .data$newspapers)
    ) |>
    dplyr::group_by(.data$keyword) |>
    dplyr::summarise(
      total_mentions = sum(.data$mentions),
      years_observed = sum(.data$mentions > 0),
      max_year_mentions = max(.data$mentions),
      usable_for_trend = .data$years_observed >= 2 & .data$total_mentions >= 10,
      sparse_or_absent = .data$total_mentions < 10,
      .groups = "drop"
    ) |>
    dplyr::arrange(.data$sparse_or_absent, dplyr::desc(.data$total_mentions), .data$keyword)
}

summarize_kwic_shares <- function(kwic_mentions) {
  if (nrow(kwic_mentions) == 0) {
    return(tibble::tibble())
  }

  kwic_mentions |>
    dplyr::group_by(.data$year) |>
    dplyr::mutate(
      total_mentions = sum(.data$mentions, na.rm = TRUE),
      mention_share = dplyr::if_else(
        .data$total_mentions > 0,
        .data$mentions / .data$total_mentions,
        NA_real_
      )
    ) |>
    dplyr::ungroup() |>
    dplyr::arrange(.data$keyword, .data$year)
}

summarize_kwic_change <- function(kwic_shares, start_year = 1850L, end_year = 1900L) {
  if (nrow(kwic_shares) == 0) {
    return(tibble::tibble())
  }

  start <- kwic_shares |>
    dplyr::filter(.data$year == start_year) |>
    dplyr::select(
      "keyword",
      start_mentions = "mentions",
      start_share = "mention_share"
    )

  end <- kwic_shares |>
    dplyr::filter(.data$year == end_year) |>
    dplyr::select(
      "keyword",
      end_mentions = "mentions",
      end_share = "mention_share"
    )

  dplyr::full_join(start, end, by = "keyword") |>
    dplyr::mutate(
      start_mentions = dplyr::if_else(is.na(.data$start_mentions), 0L, .data$start_mentions),
      end_mentions = dplyr::if_else(is.na(.data$end_mentions), 0L, .data$end_mentions),
      mention_change = .data$end_mentions - .data$start_mentions,
      share_change = .data$end_share - .data$start_share
    ) |>
    dplyr::arrange(dplyr::desc(abs(.data$share_change)))
}

kwic_stopwords <- c(
  "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "for", "from",
  "had", "has", "have", "he", "her", "his", "in", "is", "it", "its", "may", "not",
  "of", "on", "or", "our", "she", "that", "the", "their", "there", "this", "to",
  "was", "were", "which", "who", "will", "with", "you", "your"
)

context_words <- function(context) {
  words <- unlist(strsplit(tolower(context), "[^a-z]+"))
  words[nchar(words) > 2 & !(words %in% kwic_stopwords)]
}

read_glove_subset <- function(file) {
  if (!file.exists(file)) {
    return(list(words = character(), vectors = matrix(nrow = 0, ncol = 0)))
  }
  data <- utils::read.csv(file, stringsAsFactors = FALSE, check.names = FALSE)
  words <- data$word
  vectors <- as.matrix(data[, setdiff(names(data), "word"), drop = FALSE])
  storage.mode(vectors) <- "numeric"
  rownames(vectors) <- words
  list(words = words, vectors = vectors)
}

average_context_vector <- function(context, keyword, vectors) {
  words <- context_words(context)
  words <- words[words != tolower(keyword)]
  words <- intersect(words, rownames(vectors))
  if (length(words) == 0) {
    return(rep(NA_real_, ncol(vectors)))
  }
  colMeans(vectors[words, , drop = FALSE])
}

compute_alc_embeddings <- function(
    kwic,
    glove_subset,
    transform_file = "gloVe/glove_transform_enwiki_50.rds") {
  if (nrow(kwic) == 0 || nrow(glove_subset$vectors) == 0) {
    return(tibble::tibble())
  }
  if (!file.exists(transform_file)) {
    stop("GloVe transform file not found: ", transform_file, call. = FALSE)
  }

  transform <- readRDS(transform_file)
  if (ncol(glove_subset$vectors) != nrow(transform)) {
    stop("Embedding and transform dimensions do not match.", call. = FALSE)
  }

  context_vectors <- t(vapply(
    seq_len(nrow(kwic)),
    function(i) average_context_vector(kwic$context[[i]], kwic$keyword[[i]], glove_subset$vectors),
    numeric(ncol(glove_subset$vectors))
  ))

  context_data <- tibble::tibble(
    year = kwic$year,
    keyword = kwic$keyword,
    vector_id = seq_len(nrow(kwic))
  )

  valid <- stats::complete.cases(context_vectors)
  if (!any(valid)) {
    return(tibble::tibble())
  }

  grouped <- context_data[valid, , drop = FALSE] |>
    dplyr::mutate(row_id = seq_len(sum(valid))) |>
    dplyr::group_by(.data$year, .data$keyword) |>
    dplyr::summarise(
      n_contexts = dplyr::n(),
      row_ids = list(.data$row_id),
      .groups = "drop"
    )

  valid_vectors <- context_vectors[valid, , drop = FALSE]
  embedding_rows <- lapply(seq_len(nrow(grouped)), function(i) {
    context_mean <- colMeans(valid_vectors[grouped$row_ids[[i]], , drop = FALSE])
    alc <- as.numeric(context_mean %*% transform)
    tibble::tibble(
      year = grouped$year[[i]],
      keyword = grouped$keyword[[i]],
      n_contexts = grouped$n_contexts[[i]],
      dimension = seq_along(alc),
      value = alc
    )
  })

  dplyr::bind_rows(embedding_rows)
}

cosine_similarity <- function(x, y) {
  denom <- sqrt(sum(x * x)) * sqrt(sum(y * y))
  if (is.na(denom) || denom == 0) {
    return(NA_real_)
  }
  sum(x * y) / denom
}

summarize_alc_distances <- function(alc_embeddings, baseline_year = 1850L) {
  if (nrow(alc_embeddings) == 0) {
    return(tibble::tibble())
  }

  wide <- split(alc_embeddings, paste(alc_embeddings$year, alc_embeddings$keyword, sep = "\r"))
  rows <- lapply(wide, function(data) {
    tibble::tibble(
      year = data$year[[1]],
      keyword = data$keyword[[1]],
      n_contexts = data$n_contexts[[1]],
      vector = list(data$value[order(data$dimension)])
    )
  })
  vectors <- dplyr::bind_rows(rows)
  baselines <- vectors |>
    dplyr::filter(.data$year == baseline_year) |>
    dplyr::select("keyword", baseline_vector = "vector")

  dplyr::left_join(vectors, baselines, by = "keyword") |>
    dplyr::filter(!vapply(.data$baseline_vector, is.null, logical(1))) |>
    dplyr::rowwise() |>
    dplyr::mutate(
      cosine_similarity_to_baseline = cosine_similarity(.data$vector, .data$baseline_vector),
      cosine_distance_to_baseline = pmax(0, 1 - .data$cosine_similarity_to_baseline)
    ) |>
    dplyr::ungroup() |>
    dplyr::select(
      "year",
      "keyword",
      "n_contexts",
      "cosine_similarity_to_baseline",
      "cosine_distance_to_baseline"
    ) |>
    dplyr::arrange(.data$keyword, .data$year)
}

gender_seed_pairs <- function() {
  tibble::tibble(
    feminine = c(
      "she", "her", "woman", "women", "female", "girl", "mother",
      "daughter", "wife", "ladies"
    ),
    masculine = c(
      "he", "his", "man", "men", "male", "boy", "father",
      "son", "husband", "gentlemen"
    )
  )
}

construct_gender_direction <- function(
    glove_subset,
    transform_file = "gloVe/glove_transform_enwiki_50.rds") {
  if (nrow(glove_subset$vectors) == 0) {
    return(tibble::tibble())
  }
  if (!file.exists(transform_file)) {
    stop("GloVe transform file not found: ", transform_file, call. = FALSE)
  }

  transform <- readRDS(transform_file)
  pairs <- gender_seed_pairs()
  available <- pairs |>
    dplyr::filter(
      .data$feminine %in% rownames(glove_subset$vectors),
      .data$masculine %in% rownames(glove_subset$vectors)
    )

  if (nrow(available) == 0) {
    stop("No complete gender seed pairs were found in the GloVe subset.", call. = FALSE)
  }

  pair_directions <- lapply(seq_len(nrow(available)), function(i) {
    feminine <- as.numeric(glove_subset$vectors[available$feminine[[i]], , drop = TRUE] %*% transform)
    masculine <- as.numeric(glove_subset$vectors[available$masculine[[i]], , drop = TRUE] %*% transform)
    feminine - masculine
  })

  direction <- Reduce("+", pair_directions) / length(pair_directions)
  direction <- direction / sqrt(sum(direction * direction))

  tibble::tibble(
    dimension = seq_along(direction),
    value = direction,
    seed_pairs_used = nrow(available)
  )
}

embedding_vectors <- function(alc_embeddings) {
  if (nrow(alc_embeddings) == 0) {
    return(tibble::tibble())
  }

  wide <- split(alc_embeddings, paste(alc_embeddings$year, alc_embeddings$keyword, sep = "\r"))
  rows <- lapply(wide, function(data) {
    tibble::tibble(
      year = data$year[[1]],
      keyword = data$keyword[[1]],
      n_contexts = data$n_contexts[[1]],
      vector = list(data$value[order(data$dimension)])
    )
  })
  dplyr::bind_rows(rows)
}

project_embeddings_on_gender <- function(alc_embeddings, gender_direction) {
  if (nrow(alc_embeddings) == 0 || nrow(gender_direction) == 0) {
    return(tibble::tibble())
  }

  direction <- gender_direction$value[order(gender_direction$dimension)]
  seed_pairs_used <- unique(gender_direction$seed_pairs_used)
  vectors <- embedding_vectors(alc_embeddings)

  vectors |>
    dplyr::rowwise() |>
    dplyr::mutate(
      gender_projection = sum(.data$vector * direction),
      seed_pairs_used = seed_pairs_used[[1]]
    ) |>
    dplyr::ungroup() |>
    dplyr::group_by(.data$year) |>
    dplyr::mutate(
      year_mean_gender_projection = mean(.data$gender_projection, na.rm = TRUE),
      centered_gender_projection = .data$gender_projection - .data$year_mean_gender_projection
    ) |>
    dplyr::ungroup() |>
    dplyr::select(
      "year",
      "keyword",
      "n_contexts",
      "gender_projection",
      "centered_gender_projection",
      "seed_pairs_used"
    ) |>
    dplyr::arrange(.data$keyword, .data$year)
}

summarize_gender_projection_change <- function(
    gender_projections,
    start_year = min(americanstories_years),
    end_year = max(americanstories_years)) {
  if (nrow(gender_projections) == 0) {
    return(tibble::tibble())
  }

  start <- gender_projections |>
    dplyr::filter(.data$year == start_year) |>
    dplyr::select(
      "keyword",
      start_contexts = "n_contexts",
      start_gender_projection = "gender_projection",
      start_centered_gender_projection = "centered_gender_projection"
    )

  end <- gender_projections |>
    dplyr::filter(.data$year == end_year) |>
    dplyr::select(
      "keyword",
      end_contexts = "n_contexts",
      end_gender_projection = "gender_projection",
      end_centered_gender_projection = "centered_gender_projection"
    )

  dplyr::inner_join(start, end, by = "keyword") |>
    dplyr::mutate(
      projection_change = .data$end_gender_projection - .data$start_gender_projection,
      centered_projection_change = .data$end_centered_gender_projection -
        .data$start_centered_gender_projection,
      direction = dplyr::case_when(
        .data$projection_change > 0 ~ "more feminine",
        .data$projection_change < 0 ~ "more masculine",
        TRUE ~ "no change"
      ),
      centered_direction = dplyr::case_when(
        .data$centered_projection_change > 0 ~ "more feminine relative to year",
        .data$centered_projection_change < 0 ~ "more masculine relative to year",
        TRUE ~ "no relative change"
      )
    ) |>
    dplyr::arrange(dplyr::desc(abs(.data$projection_change)))
}

summarize_kwic_context_words <- function(kwic, top_n = 20L) {
  if (nrow(kwic) == 0) {
    return(tibble::tibble())
  }

  rows <- lapply(seq_len(nrow(kwic)), function(i) {
    words <- context_words(kwic$context[[i]])
    words <- words[words != tolower(kwic$keyword[[i]])]
    if (length(words) == 0) {
      return(NULL)
    }
    tibble::tibble(
      year = kwic$year[[i]],
      keyword = kwic$keyword[[i]],
      word = words
    )
  })

  dplyr::bind_rows(rows) |>
    dplyr::count(.data$year, .data$keyword, .data$word, name = "n", sort = TRUE) |>
    dplyr::group_by(.data$year, .data$keyword) |>
    dplyr::slice_max(order_by = .data$n, n = top_n, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::arrange(.data$keyword, .data$year, dplyr::desc(.data$n))
}

sample_kwic_contexts <- function(kwic, n_per_year_keyword = 3L) {
  if (nrow(kwic) == 0) {
    return(tibble::tibble())
  }

  kwic |>
    dplyr::group_by(.data$year, .data$keyword) |>
    dplyr::slice_head(n = n_per_year_keyword) |>
    dplyr::ungroup() |>
    dplyr::arrange(.data$keyword, .data$year) |>
    dplyr::select(
      "year",
      "keyword",
      "date",
      "newspaper_name",
      "article_id",
      "context"
    )
}

bridge_kwic_to_ipums <- function(kwic_mentions, ipums_occupations) {
  if (nrow(kwic_mentions) == 0 || nrow(ipums_occupations) == 0) {
    return(tibble::tibble())
  }

  keywords <- unique(kwic_mentions$keyword)
  rows <- lapply(keywords, function(keyword) {
    matches <- grepl(
      tolower(keyword),
      tolower(ipums_occupations$occstr),
      fixed = TRUE
    )
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
