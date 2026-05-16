# Created by use_targets().
# Follow the comments below to fill in this target script.
# Then follow the manual to check and run the pipeline:
#   https://books.ropensci.org/targets/walkthrough.html#inspect-the-pipeline

# Load packages required to define the pipeline:
library(targets)
# library(tarchetypes) # Load other packages as needed.

# Set target options:
tar_option_set(
  packages = c("dplyr", "tibble") # Packages that your targets need for their tasks.
  # format = "qs", # Optionally set the default storage format. qs is fast.
  #
  # Pipelines that take a long time to run may benefit from
  # optional distributed computing. To use this capability
  # in tar_make(), supply a {crew} controller
  # as discussed at https://books.ropensci.org/targets/crew.html.
  # Choose a controller that suits your needs. For example, the following
  # sets a controller that scales up to a maximum of two workers
  # which run as local R processes. Each worker launches when there is work
  # to do and exits if 60 seconds pass with no tasks to run.
  #
  #   controller = crew::crew_controller_local(workers = 2, seconds_idle = 60)
  #
  # Alternatively, if you want workers to run on a high-performance computing
  # cluster, select a controller from the {crew.cluster} package.
  # For the cloud, see plugin packages like {crew.aws.batch}.
  # The following example is a controller for Sun Grid Engine (SGE).
  #
  #   controller = crew.cluster::crew_controller_sge(
  #     # Number of workers that the pipeline can scale up to:
  #     workers = 10,
  #     # It is recommended to set an idle time so workers can shut themselves
  #     # down if they are not running tasks.
  #     seconds_idle = 120,
  #     # Many clusters install R as an environment module, and you can load it
  #     # with the script_lines argument. To select a specific verison of R,
  #     # you may need to include a version string, e.g. "module load R/4.3.2".
  #     # Check with your system administrator if you are unsure.
  #     script_lines = "module load R"
  #   )
  #
  # Set other options as needed.
)

# Run the R scripts in the R/ folder with your custom functions:
tar_source()
# tar_source("other_functions.R") # Source other scripts as needed.


list(
  tar_target(
    name = kwic_terms_file,
    command = "data/kwic_terms_example.txt",
    format = "file"
  ),
  tar_target(
    name = occupation_terms,
    command = read_terms_file(kwic_terms_file)
  ),
  tar_target(
    name = ipums_manifest,
    command = prepare_ipums_data(),
    format = "file",
    cue = tar_cue(mode = "always")
  ),
  tar_target(
    name = americanstories_kwic_file,
    command = run_americanstories_kwic(terms_file = kwic_terms_file),
    format = "file"
  ),
  tar_target(
    name = glove_subset_script,
    command = "scripts/subset_glove.py",
    format = "file"
  ),
  tar_target(
    name = glove_vocab_embeddings_file,
    command = {
      americanstories_kwic_file
      glove_subset_script
      run_glove_subset()
    },
    format = "file"
  ),
  tar_target(
    name = ipums_files,
    command = {
      ipums_manifest
      list_ipums_files()
    }
  ),
  tar_target(
    name = kwic_files,
    command = {
      americanstories_kwic_file
      list_kwic_files()
    }
  ),
  tar_target(
    name = ipums_microdata,
    command = read_ipums_microdata(ipums_files)
  ),
  tar_target(
    name = americanstories_kwic,
    command = read_kwic_data(americanstories_kwic_file)
  ),
  tar_target(
    name = ipums_occupations,
    command = summarize_ipums_occupations(ipums_microdata)
  ),
  tar_target(
    name = americanstories_mentions,
    command = summarize_kwic_mentions(americanstories_kwic)
  ),
  tar_target(
    name = americanstories_term_coverage,
    command = summarize_term_coverage(occupation_terms, americanstories_mentions)
  ),
  tar_target(
    name = americanstories_keyword_shares,
    command = summarize_kwic_shares(americanstories_mentions)
  ),
  tar_target(
    name = americanstories_keyword_change,
    command = summarize_kwic_change(americanstories_keyword_shares)
  ),
  tar_target(
    name = americanstories_context_words,
    command = summarize_kwic_context_words(americanstories_kwic)
  ),
  tar_target(
    name = americanstories_context_samples,
    command = sample_kwic_contexts(americanstories_kwic)
  ),
  tar_target(
    name = glove_vocab_embeddings,
    command = read_glove_subset(glove_vocab_embeddings_file)
  ),
  tar_target(
    name = americanstories_alc_embeddings,
    command = compute_alc_embeddings(americanstories_kwic, glove_vocab_embeddings)
  ),
  tar_target(
    name = americanstories_alc_distances,
    command = summarize_alc_distances(americanstories_alc_embeddings)
  ),
  tar_target(
    name = gender_direction,
    command = construct_gender_direction(glove_vocab_embeddings)
  ),
  tar_target(
    name = americanstories_gender_projections,
    command = project_embeddings_on_gender(americanstories_alc_embeddings, gender_direction)
  ),
  tar_target(
    name = americanstories_gender_projection_change,
    command = summarize_gender_projection_change(americanstories_gender_projections)
  ),
  tar_target(
    name = occupation_language_bridge,
    command = bridge_kwic_to_ipums(americanstories_mentions, ipums_occupations)
  )
  # tarchetypes::tar_render(manuscript, "manuscript/manuscript.Rmd")
)
