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
