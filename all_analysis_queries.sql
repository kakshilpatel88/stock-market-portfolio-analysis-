-- Stock Market Portfolio Performance & Risk Analysis
-- BigQuery Standard SQL
-- Before running: replace YOUR_PROJECT_ID with your Google Cloud project ID.
-- First upload data/stock_observations.csv as:
-- YOUR_PROJECT_ID.stock_portfolio.stock_observations
-- Suggested column types are listed in BIGQUERY_SETUP.md.

CREATE SCHEMA IF NOT EXISTS `YOUR_PROJECT_ID.stock_portfolio`
OPTIONS(location='US');

-- 1. Clean analytical view
CREATE OR REPLACE VIEW `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data` AS
SELECT
  SAFE_CAST(Date AS DATE) AS trade_date,
  UPPER(TRIM(Ticker)) AS ticker,
  TRIM(Sector) AS sector,
  SAFE_CAST(Close AS FLOAT64) AS close_price,
  SAFE_CAST(Volume AS INT64) AS volume,
  SAFE_CAST(Period_Return AS FLOAT64) AS period_return,
  SAFE_CAST(Running_Peak AS FLOAT64) AS running_peak,
  SAFE_CAST(Drawdown AS FLOAT64) AS drawdown,
  SAFE_CAST(Year AS INT64) AS year,
  TRIM(Quarter) AS quarter,
  TRIM(Month) AS month
FROM `YOUR_PROJECT_ID.stock_portfolio.stock_observations`
WHERE SAFE_CAST(Date AS DATE) IS NOT NULL
  AND Ticker IS NOT NULL
  AND SAFE_CAST(Close AS FLOAT64) > 0;

-- 2. Data quality checks
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT ticker) AS ticker_count,
  COUNTIF(trade_date IS NULL) AS missing_dates,
  COUNTIF(ticker IS NULL OR ticker = '') AS missing_tickers,
  COUNTIF(close_price IS NULL OR close_price <= 0) AS invalid_close_prices,
  COUNTIF(volume IS NULL OR volume < 0) AS invalid_volumes,
  COUNT(*) - COUNT(DISTINCT CONCAT(ticker, '|', CAST(trade_date AS STRING))) AS duplicate_ticker_date_rows
FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data`;

-- 3. Recalculate close-to-close returns and drawdown; compare with supplied derived fields
WITH calculated AS (
  SELECT *,
    LAG(close_price) OVER(PARTITION BY ticker ORDER BY trade_date) AS prior_close,
    MAX(close_price) OVER(PARTITION BY ticker ORDER BY trade_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS recalculated_peak
  FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data`
)
SELECT
  trade_date, ticker, close_price,
  SAFE_DIVIDE(close_price - prior_close, prior_close) AS recalculated_period_return,
  period_return AS supplied_period_return,
  recalculated_peak,
  SAFE_DIVIDE(close_price, recalculated_peak) - 1 AS recalculated_drawdown,
  drawdown AS supplied_drawdown
FROM calculated
ORDER BY ticker, trade_date;

-- 4. Stock-level performance and risk
WITH metrics AS (
  SELECT
    ticker,
    ANY_VALUE(sector) AS sector,
    ARRAY_AGG(close_price ORDER BY trade_date LIMIT 1)[OFFSET(0)] AS start_price,
    ARRAY_AGG(close_price ORDER BY trade_date DESC LIMIT 1)[OFFSET(0)] AS end_price,
    MIN(drawdown) AS max_observed_drawdown,
    AVG(period_return) AS average_observed_period_return,
    AVG(volume) AS average_observed_volume,
    COUNT(*) AS observation_count,
    DATE_DIFF(MAX(trade_date), MIN(trade_date), DAY) AS elapsed_days
  FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data`
  GROUP BY ticker
)
SELECT *,
  SAFE_DIVIDE(end_price, start_price) - 1 AS total_price_return,
  POW(SAFE_DIVIDE(end_price, start_price), SAFE_DIVIDE(365.25, elapsed_days)) - 1 AS cagr
FROM metrics
ORDER BY total_price_return DESC;

-- 5. Sector-level performance (exclude simulated benchmark)
WITH stock_metrics AS (
  SELECT ticker, ANY_VALUE(sector) AS sector,
    SAFE_DIVIDE(ARRAY_AGG(close_price ORDER BY trade_date DESC LIMIT 1)[OFFSET(0)],
                ARRAY_AGG(close_price ORDER BY trade_date LIMIT 1)[OFFSET(0)]) - 1 AS total_return,
    MIN(drawdown) AS max_drawdown
  FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data`
  WHERE ticker <> 'MKT'
  GROUP BY ticker
)
SELECT sector, COUNT(*) AS stock_count,
  AVG(total_return) AS average_total_return,
  AVG(max_drawdown) AS average_max_drawdown
FROM stock_metrics
GROUP BY sector
ORDER BY average_total_return DESC;

-- 6. Year and ticker observations
SELECT year, ticker,
  COUNT(*) AS observations,
  AVG(period_return) AS average_observed_period_return,
  MIN(close_price) AS lowest_observed_close,
  MAX(close_price) AS highest_observed_close
FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data`
GROUP BY year, ticker
ORDER BY year, ticker;

-- 7. Maximum drawdown ranking
SELECT ticker, ANY_VALUE(sector) AS sector,
  MIN(drawdown) AS max_observed_drawdown
FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data`
GROUP BY ticker
ORDER BY max_observed_drawdown ASC;

-- 8. Estimated beta vs simulated MKT; sparse sample, descriptive only
WITH paired_returns AS (
  SELECT s.ticker, s.period_return AS stock_return, m.period_return AS market_return
  FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data` s
  JOIN `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data` m
    ON s.trade_date = m.trade_date
  WHERE s.ticker <> 'MKT'
    AND m.ticker = 'MKT'
    AND s.period_return IS NOT NULL
    AND m.period_return IS NOT NULL
)
SELECT ticker,
  COVAR_SAMP(stock_return, market_return) / VAR_SAMP(market_return) AS beta_vs_simulated_mkt,
  CORR(stock_return, market_return) AS correlation_vs_simulated_mkt,
  COUNT(*) AS paired_observations
FROM paired_returns
GROUP BY ticker
ORDER BY beta_vs_simulated_mkt DESC;

-- 9. Volume analysis; MKT has zero volume by construction, so exclude it
SELECT ticker, ANY_VALUE(sector) AS sector,
  AVG(volume) AS average_volume,
  MAX(volume) AS maximum_volume,
  SUM(volume) AS total_observed_volume
FROM `YOUR_PROJECT_ID.stock_portfolio.vw_clean_stock_data`
WHERE ticker <> 'MKT'
GROUP BY ticker
ORDER BY average_volume DESC;
