# Readme <a href='https://doi.org/10.3233/DS-210031'><img src='worcs_icon.png' align="right" height="139" /></a>

<!-- Below, project badges will be added. -->

<!-- badges: start -->

<!-- badges: end -->

<!-- Please add a brief introduction to explain what the project is about    -->

## Where do I start?

You can load this project in RStudio by opening the file called 'devaluation.Rproj'.

## American Stories KWIC extraction

This project includes a lightweight extractor for keyword-in-context rows from
the American Stories dataset. American Stories is distributed as one compressed
archive per year, so the extractor scans selected years and writes only matching
contexts to CSV.

Example pilot run:

```bash
conda run -n amstories python scripts/americanstories_kwic.py \
  --years 1870 \
  --terms-file data/kwic_terms_example.txt \
  --window 50 \
  --max-rows-per-year-term 1000 \
  --max-articles 5000 \
  --timeout-seconds 600 \
  --out data/kwic/americanstories_1870_pilot.csv
```

To keep downloaded yearly archives for reuse, add a cache directory and
`--keep-archives`:

```bash
conda run -n amstories python scripts/americanstories_kwic.py \
  --years 1870 1880 1890 \
  --terms nurse teacher secretary \
  --window 50 \
  --cache-dir data/raw/americanstories \
  --keep-archives \
  --out data/kwic/americanstories_kwic.csv
```

The output includes article metadata, `left`, `match`, `right`, and a combined
`context` column that can be passed into downstream R workflows such as
`conText`.

## IPUMS 1850-1880 extract

Add your IPUMS API token to `.Renviron`:

```r
IPUMS_API_KEY=your_token_here
```

Then request, check, and download the IPUMS USA 1% samples for 1850, 1860, 1870,
and 1880 with the Python data step:

```bash
python scripts/ipums_extract.py submit
python scripts/ipums_extract.py status
python scripts/ipums_extract.py download
```

The extract definition is stored in
`data/ipums/metadata/ipums_usa_1850_1880_extract_request.json`. Downloaded CSV
files should land under `data/ipums/raw/`, which is ignored by git.

## Analysis pipeline

The `targets` pipeline now calls external Python scripts for data preparation:

- `scripts/ipums_extract.py` lists local IPUMS files by default, or submits and
  downloads the extract when `DOWNLOAD_IPUMS=true`.
- `scripts/americanstories_kwic.py` downloads/caches American Stories yearly
  archives and writes KWIC rows for 1850, 1860, 1870, 1880, 1890, and 1900.

Then it reads IPUMS CSV files from `data/ipums/`, American Stories KWIC CSV files
from `data/kwic/`, and creates analysis objects. The American Stories workflow
currently covers 1850-1900 in ten-year steps; the current IPUMS extract covers
1850-1880.

```r
targets::tar_make()
targets::tar_read(ipums_occupations)
targets::tar_read(americanstories_mentions)
targets::tar_read(occupation_language_bridge)
```

To let `targets` submit/download the IPUMS extract through Python, run:

```bash
DOWNLOAD_IPUMS=true Rscript -e "targets::tar_make()"
```

If you want the pipeline to wait while IPUMS prepares the extract, also set
`WAIT_IPUMS=true`.

The American Stories target defaults to a bounded pilot scan of 5,000 articles
per year so the workflow completes during development. Raise or remove that
limit with `AMSTORIES_MAX_ARTICLES_PER_YEAR` when you are ready for a larger
run.

On machines where Python's local certificate store rejects the API or Hugging
Face certificate chain, set `IPUMS_INSECURE_SSL=1` or
`AMSTORIES_INSECURE_SSL=1` for the affected run. These are explicit local
fallbacks; leave them unset when normal certificate validation works.

`ipums_occupations` summarizes weighted occupational composition and female
share by year and `OCC1950`. `americanstories_mentions` summarizes keyword
mentions by year. `occupation_language_bridge` gives a first-pass match between
KWIC keywords and IPUMS occupation strings.

## ALC embeddings

Place the pretrained GloVe files under `gloVe/`:

```text
gloVe/glove_vectors_enwiki.txt
gloVe/glove_transform_enwiki_50.rds
```

The pipeline subsets the large GloVe text file to the American Stories KWIC
vocabulary with `scripts/subset_glove.py`, then calculates ALC-style embeddings
from KWIC context words and the supplied transform matrix:

```r
targets::tar_make(americanstories_alc_distances)
targets::tar_read(americanstories_alc_distances)
```

The derived vocabulary embedding file is written under `data/embeddings/` and
ignored by git.

## Project structure

<!--  You can add rows to this table, using "|" to separate columns.         -->
File                      | Description                      | Usage         
------------------------- | -------------------------------- | --------------
README.md                 | Description of project           | Human editable
devaluation.Rproj         | Project file                     | Loads project 
.worcs                    | WORCS metadata YAML              | Read only     
prepare_data.R            | Script to process raw data       | Human editable
manuscript/manuscript.Rmd | Source code for paper            | Human editable
manuscript/references.bib | BibTex references for manuscript | Human editable
renv.lock                 | Reproducible R environment       | Read only     

<!--  You can consider adding the following to this file:                    -->
<!--  * A citation reference for your project                                -->
<!--  * Contact information for questions/comments                           -->
<!--  * How people can offer to contribute to the project                    -->
<!--  * A contributor code of conduct, https://www.contributor-covenant.org/ -->

# Reproducibility

This project uses the Workflow for Open Reproducible Code in Science (WORCS) to
ensure transparency and reproducibility. The workflow is designed to meet the
principles of Open Science throughout a research project. 

To learn how WORCS helps researchers meet the TOP-guidelines and FAIR principles,
read the paper at https://doi.org/10.3233/DS-210031

## WORCS: Advice for authors

* To get started with `worcs`, see the [setup vignette](https://cjvanlissa.github.io/worcs/articles/setup.html)
* For detailed information about the steps of the WORCS workflow, see the [workflow vignette](https://cjvanlissa.github.io/worcs/articles/workflow.html)

## WORCS: Advice for readers

Please refer to the vignette on [reproducing a WORCS project](https://cjvanlissa.github.io/worcs/articles/reproduce.html) for step by step advice.
<!-- If your project deviates from the steps outlined in the vignette on     -->
<!-- reproducing a WORCS project, please provide your own advice for         -->
<!-- readers here.                                                           -->
