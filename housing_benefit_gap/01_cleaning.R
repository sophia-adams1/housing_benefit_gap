# ==============================================================================
# PROJECT: UK Housing Benefit-Gap Analysis
# SCRIPT:  01_cleaning.R
# AUTHOR: Sophia Adams
# PURPOSE: Load, validate, clean and merge ONS rental data with genuine
#          multi-year / region-level LHA rates. This script outputs a single master
#          dataset for econometric analysis.
# ==============================================================================

# --- 1. SETUP & DEPENDENCIES ---

library(tidyverse)
library(janitor)
library(here)
library(readxl)
library(lubridate)

ENGLISH_REGIONS <- c("North East", "North West", "Yorkshire and The Humber",
                      "East Midlands", "West Midlands", "East of England",
                      "London", "South East", "South West")

# --- 2. RENTAL DATA -- USED ONS'S OWN REGION-LEVEL ROWS DIRECTLY ---
# The raw file contains local-authority-level rows AND pre-built regional
# rows (area_name == a region name). Using ONS's own regional aggregate
# is more defensible than building one manually, and this needs no lookup file.

raw_rental_data <- read_excel(
  here("data", "priceindexofprivaterentsukmonthlypricestatistics.xlsx"),
  sheet = "Table 1",
  skip = 2
) %>%
  clean_names()

# --- 3. LHA RATES -- MULTI-YEAR, AGGREGATED TO THE SAME 9 REGIONS ---

# Financial-year helper: LHA years run April to March, so January 2022
# belongs to FY "2021-22", but April 2022 belongs to FY "2022-23".
fy_label <- function(date) {
  date <- as.Date(date)
  yr <- year(date)
  mo <- month(date)
  start_yr <- if_else(mo >= 4, yr, yr - 1)
  paste0(start_yr, "-", str_sub(as.character(start_yr + 1), 3, 4))
}

brma_region_lookup <- read_csv(here("data", "brma_region_lookup.csv")) %>%
  clean_names()

# 3a. Historical weekly rates, 2015-16 to 2021-22
lha_historical <- read_csv(here("data", "lha-rates-weekly-all-years-open.csv")) %>%
  clean_names() %>%
  select(brma = brma_name, matches("^x\\d{4}_\\d{2}_1_bed_weekly_rate$")) %>%
  pivot_longer(-brma, names_to = "financial_year", values_to = "cat_b_weekly") %>%
  mutate(financial_year = str_extract(financial_year, "\\d{4}_\\d{2}") %>% str_replace("_", "-")) %>%
  filter(financial_year >= "2015-16")

# 3b. Recent years, 2022-23 to 2025-26, one official DWP table per year
read_lha_table4 <- function(path, financial_year_label) {
  read_excel(path, sheet = "Table 4") %>%
    janitor::row_to_names(row_number = 1) %>%
    janitor::clean_names() %>%
    transmute(brma, financial_year = financial_year_label, cat_b_weekly = as.numeric(cat_b))
}

lha_recent <- bind_rows(
  read_lha_table4(here("data", "2022-23_LHA_TABLES.xlsx"), "2022-23"),
  read_lha_table4(here("data", "2023-24_LHA_TABLES.xlsx"), "2023-24"),
  read_lha_table4(here("data", "2024-25_LHA_TABLES.xlsx"), "2024-25"),
  read_lha_table4(here("data", "2025-26_LHA_TABLES.xlsx"), "2025-26")
)

# 3c. Combine, attach region, and aggregate BRMAs up to region level.
# Aggregation is an unweighted mean across BRMAs within each region -- no
# population/stock weighting data is available, so this is a stated
# simplification, not a precise claim.
lha_by_region <- bind_rows(lha_historical, lha_recent) %>%
  left_join(brma_region_lookup, by = "brma") %>%
  filter(!is.na(region)) %>%
  group_by(region, financial_year) %>%
  summarise(cat_b_weekly_mean = mean(cat_b_weekly, na.rm = TRUE), .groups = "drop") %>%
  mutate(cat_b = cat_b_weekly_mean * 52 / 12) %>%   # weekly -> monthly, matching rental_price's units
  select(region, financial_year, cat_b)

message("LHA regional panel built: ", n_distinct(lha_by_region$region), " regions across ",
        n_distinct(lha_by_region$financial_year), " financial years (",
        min(lha_by_region$financial_year), " to ", max(lha_by_region$financial_year), ")")

# ==============================================================================

# --- 4a. SCHEMA VALIDATION (CHECK BEFORE CLEANING) ---
required_cols <- c("time_period", "area_name", "index")
missing_cols <- setdiff(required_cols, colnames(raw_rental_data))
if (length(missing_cols) > 0) {
  stop(paste("Validation failed: missing columns in source file:",
             paste(missing_cols, collapse = ", ")))
}
message("SUCCESS: Data loaded and validated. Row count: ", nrow(raw_rental_data))

# --- 4b. DATA CLEANING ---
clean_data <- raw_rental_data %>%
  filter(area_name %in% ENGLISH_REGIONS) %>%   # Kept ONLY the 9 official region rows
  mutate(across(where(is.character), str_trim)) %>%
  mutate(across(where(is.character), ~ na_if(., "[x]"))) %>%
  mutate(across(where(is.character), ~ na_if(., "[z]"))) %>%
  mutate(index = as.numeric(index)) %>%
  mutate(across(starts_with("rental_price"), as.numeric)) %>%
  rename(region = area_name)

if (!is.numeric(clean_data$index)) {
  stop("Validation failed: 'index' column is not numeric. Check for non-numeric characters.")
}
message("Success, data cleaned and integrity verified. Rows: ", nrow(clean_data))

# ==============================================================================

# --- 5. JOINING & BENEFIT GAP CALCULATION ---
analysis_data <- clean_data %>%
  mutate(financial_year = fy_label(time_period)) %>%
  left_join(lha_by_region, by = c("region", "financial_year")) %>%
  mutate(
    rental_price = as.numeric(rental_price),
    cat_b = as.numeric(cat_b),
    gap = rental_price - cat_b
  )

# ==============================================================================

# --- 6. AUDIT & REPORT ---
audit_log <- list(
  total_rows = nrow(analysis_data),
  distinct_regions = n_distinct(analysis_data$region),
  nas_in_gap = sum(is.na(analysis_data$gap)),
  timestamp = Sys.time()
)

cat("\n--- DATA AUDIT REPORT ---\n")
print(audit_log)
cat("---------------------------\n")

if (!dir.exists(here("data-processed"))) dir.create(here("data-processed"))

glimpse(analysis_data)

write_csv(analysis_data, here("data-processed", "master_rental_gap_data.csv"))

message("SUCCESS: Pipeline complete. Master dataset saved to /data-processed/master_rental_gap_data.csv")
