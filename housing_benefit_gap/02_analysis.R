# ==============================================================================
# PROJECT: UK Housing Benefit Gap Analysis
# SCRIPT:  02_analysis.R
# AUTHOR: Sophia Adams
# PURPOSE: Estimate a fixed-effects panel model of the housing benefit gap,
#          and produce the trend and regional divergence figures.
#
# Ensure 01_cleaning.R has been run first, producing
# data-processed/master_rental_gap_data.csv.
# ==============================================================================

library(tidyverse)
library(fixest)
library(here)

dir.create(here("outputs"), showWarnings = FALSE)  # So saved figures have somewhere to go

analysis_data <- read_csv(here("data-processed", "master_rental_gap_data.csv"))

# --- 1. TREND CHART: AVERAGE GAP OVER TIME ---
trend_plot <- analysis_data %>%
  group_by(time_period) %>%
  summarise(mean_gap = mean(gap, na.rm = TRUE), .groups = "drop") %>%
  ggplot(aes(x = time_period, y = mean_gap)) +
  geom_line(color = "darkred", linewidth = 1) +
  labs(
    title = "Average Rental Gap Trend (2015-2026)",
    x = "Year", y = "Average Gap (£)"
  ) +
  theme_minimal()

ggsave(here("outputs", "figure1_average_gap_trend.png"), trend_plot, width = 8, height = 5, dpi = 300)
print(trend_plot)

# --- 2. REGIONAL DIVERGENCE ---
regional_plot <- analysis_data %>%
  ggplot(aes(x = time_period, y = gap)) +
  geom_line(color = "steelblue", linewidth = 1) +
  facet_wrap(~ region) +
  labs(
    title = "Regional Divergence in Rental Affordability",
    x = "Year", y = "Average Gap (£)"
  ) +
  theme_minimal()

ggsave(here("outputs", "figure2_regional_divergence.png"), regional_plot, width = 10, height = 7, dpi = 300)
print(regional_plot)

# --- 3. FIXED-EFFECTS MODEL ---
analysis_data <- analysis_data %>%
  mutate(time_numeric = as.numeric(difftime(time_period, min(time_period), units = "days")) / 365.25)

model <- feols(
  gap ~ time_numeric | region,
  data = analysis_data,
  cluster = ~region
)

summary(model)

# --- 4. SAVE MODEL SUMMARY TO FILE ---
sink(here("outputs", "model_summary.txt"))
summary(model)
sink()

message("SUCCESS: Figures and model summary saved to /outputs/")
