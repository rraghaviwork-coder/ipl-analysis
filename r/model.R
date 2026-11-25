# IPL Elo ratings + match outcome model (R)
#
# Reads data/matches.csv and writes data/model.json, which the Flask app serves
# at /api/model and uses for /api/predict.
#
#   Rscript r/model.R            (from the project root)
#
# What it does
#   1. Elo ratings: every team starts at 1500 and is updated after each match
#      (K = 24). At the start of each season ratings regress 30% toward 1500.
#   2. Pre-match features for every match, using only information available
#      before the first ball (no leakage):
#        elo    rating difference / 100
#        form   difference in win rate over each side's last 10 matches
#        toss   +1 if team A won the toss, -1 if team B did
#        bat    +1 if team A batted first, -1 if team B did
#        home   +1 if at team A's home ground, -1 if team B's, 0 if neutral
#   3. Logistic regression (glm, binomial) with no intercept. Every feature is
#      antisymmetric, so P(A beats B) = 1 - P(B beats A) exactly.
#      Trained on earlier seasons, tested on the latest 3, then refit on all.
#   4. Likelihood-ratio tests per feature, odds ratios with 95% CIs,
#      calibration table and the biggest upsets.
#
# Dependencies: base R + jsonlite

suppressPackageStartupMessages(library(jsonlite))

args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", args[grep("^--file=", args)])
root <- if (length(script)) normalizePath(file.path(dirname(script), "..")) else getwd()
in_file <- file.path(root, "data", "matches.csv")
out_file <- file.path(root, "data", "model.json")

K <- 24          # Elo update speed
START <- 1500    # starting rating
CARRY <- 0.70    # share of rating carried into a new season
FORM_N <- 10     # matches in the form window
TEST_SEASONS <- 3

# ---------------------------------------------------------------- load + clean
renames <- c("Delhi Daredevils" = "Delhi Capitals",
             "Kings XI Punjab" = "Punjab Kings",
             "Royal Challengers Bangalore" = "Royal Challengers Bengaluru",
             "Rising Pune Supergiants" = "Rising Pune Supergiant")
rename <- function(x) ifelse(x %in% names(renames), renames[x], x)

d <- read.csv(in_file, stringsAsFactors = FALSE, na.strings = c("NA", ""))
for (col in c("team1", "team2", "toss_winner", "winner", "eliminator")) d[[col]] <- rename(d[[col]])
d$winner <- ifelse(is.na(d$winner), d$eliminator, d$winner)   # super-over winner
d$match_date <- as.Date(d$match_date)
d$season <- as.integer(format(d$match_date, "%Y"))
d <- d[order(d$match_date, d$match_number), ]
other <- ifelse(d$toss_winner == d$team1, d$team2, d$team1)
d$bat_first <- ifelse(d$toss_decision == "bat", d$toss_winner, other)

# Home grounds, matched against "venue, city" (case-insensitive)
home_pattern <- c(
  "Chennai Super Kings" = "chepauk|chennai",
  "Mumbai Indians" = "wankhede|mumbai|brabourne",
  "Royal Challengers Bengaluru" = "chinnaswamy|bangalore|bengaluru",
  "Kolkata Knight Riders" = "eden gardens|kolkata",
  "Sunrisers Hyderabad" = "uppal|hyderabad",
  "Deccan Chargers" = "uppal|hyderabad",
  "Rajasthan Royals" = "sawai mansingh|jaipur",
  "Delhi Capitals" = "feroz shah|arun jaitley|delhi",
  "Punjab Kings" = "mohali|mullanpur|chandigarh|dharamsala",
  "Gujarat Titans" = "narendra modi|motera|ahmedabad",
  "Gujarat Lions" = "rajkot|saurashtra",
  "Lucknow Super Giants" = "ekana|lucknow",
  "Pune Warriors" = "subrata roy|pune",
  "Rising Pune Supergiant" = "maharashtra cricket|pune",
  "Kochi Tuskers Kerala" = "nehru stadium|kochi"
)
place <- tolower(paste(d$venue, d$city))
is_home <- function(team, i) {
  p <- home_pattern[team]
  !is.na(p) && grepl(p, place[i])
}
# Mumbai venues host many neutral games (2022 bubble): only count as home
# when the season had a normal home-and-away schedule.
neutral_seasons <- c(2009L, 2014L, 2020L, 2021L, 2022L)

# ------------------------------------------------------- Elo + feature pass
teams <- sort(unique(c(d$team1, d$team2)))
elo <- setNames(rep(START, length(teams)), teams)
recent <- setNames(vector("list", length(teams)), teams)
form_of <- function(t) if (length(recent[[t]])) mean(recent[[t]]) else 0.5

n <- nrow(d)
feat <- data.frame(elo = numeric(n), form = numeric(n), toss = numeric(n),
                   bat = numeric(n), home = numeric(n), y = NA_real_,
                   elo_a = numeric(n), elo_b = numeric(n))
history <- list()
cur_season <- d$season[1]

for (i in seq_len(n)) {
  s <- d$season[i]
  if (s != cur_season) {
    history[[as.character(cur_season)]] <- elo
    elo <- START + CARRY * (elo - START)
    cur_season <- s
  }
  a <- d$team1[i]; b <- d$team2[i]
  home <- 0
  if (!(s %in% neutral_seasons)) home <- is_home(a, i) - is_home(b, i)
  feat[i, ] <- list((elo[a] - elo[b]) / 100, form_of(a) - form_of(b),
                    ifelse(d$toss_winner[i] == a, 1, -1),
                    ifelse(d$bat_first[i] == a, 1, -1), home, NA,
                    elo[a], elo[b])

  w <- d$winner[i]
  if (!is.na(w) && w %in% c(a, b)) {
    ya <- as.numeric(w == a)
    feat$y[i] <- ya
    ea <- 1 / (1 + 10^((elo[b] - elo[a]) / 400))
    elo[a] <- elo[a] + K * (ya - ea)
    elo[b] <- elo[b] - K * (ya - ea)
    recent[[a]] <- tail(c(recent[[a]], ya), FORM_N)
    recent[[b]] <- tail(c(recent[[b]], 1 - ya), FORM_N)
  }
}
history[[as.character(cur_season)]] <- elo
feat$season <- d$season

# ------------------------------------------------------------------- modelling
fml <- y ~ 0 + elo + form + toss + bat + home
dm <- feat[!is.na(feat$y), ]
seasons <- sort(unique(dm$season))
test_from <- seasons[length(seasons) - TEST_SEASONS + 1]
train <- dm[dm$season < test_from, ]
test <- dm[dm$season >= test_from, ]

metrics <- function(p, y) list(
  accuracy = round(mean((p >= 0.5) == (y == 1)) * 100, 1),
  log_loss = round(-mean(y * log(p) + (1 - y) * log(1 - p)), 4),
  brier = round(mean((p - y)^2), 4)
)
fit_train <- glm(fml, binomial, train)
fit_elo <- glm(y ~ 0 + elo, binomial, train)
p_test <- predict(fit_train, test, type = "response")
p_elo <- predict(fit_elo, test, type = "response")

evaluation <- list(
  train_seasons = sprintf("%d-%d", min(train$season), max(train$season)),
  test_seasons = sprintf("%d-%d", test_from, max(seasons)),
  n_train = nrow(train), n_test = nrow(test),
  model = metrics(p_test, test$y),
  elo_only = metrics(p_elo, test$y),
  coin_flip = modifyList(metrics(rep(0.5, nrow(test)), test$y), list(accuracy = 50))
)

# Calibration on the test set, from the favourite's point of view
fav_p <- pmax(p_test, 1 - p_test)
fav_won <- ifelse(p_test >= 0.5, test$y, 1 - test$y)
bins <- cut(fav_p, c(0.5, 0.55, 0.6, 0.65, 0.7, 1), include.lowest = TRUE)
calibration <- lapply(levels(bins), function(l) {
  k <- bins == l
  list(bin = l, n = sum(k),
       predicted = if (any(k)) round(mean(fav_p[k]) * 100, 1) else NULL,
       actual = if (any(k)) round(mean(fav_won[k]) * 100, 1) else NULL)
})
calibration <- Filter(function(r) r$n > 0, calibration)

# Final model on all seasons
fit <- glm(fml, binomial, dm)
co <- summary(fit)$coefficients
ci <- confint.default(fit)
lrt <- drop1(fit, test = "LRT")
labels <- c(elo = "Elo rating gap (per 100 pts)",
            form = "Recent form gap (last 10)",
            toss = "Won the toss",
            bat = "Batted first",
            home = "Home ground")
coefficients <- lapply(rownames(co), function(v) list(
  term = v, label = unname(labels[v]),
  estimate = round(co[v, 1], 4), std_error = round(co[v, 2], 4),
  odds_ratio = round(exp(co[v, 1]), 3),
  ci_low = round(exp(ci[v, 1]), 3), ci_high = round(exp(ci[v, 2]), 3),
  p_value = signif(lrt[v, "Pr(>Chi)"], 3)
))

# Biggest upsets: lowest pre-match probability for the eventual winner
p_all <- fitted(fit)
p_winner <- ifelse(dm$y == 1, p_all, 1 - p_all)
idx <- which(!is.na(feat$y))[order(p_winner)][1:10]
upsets <- lapply(seq_along(idx), function(j) {
  i <- idx[j]
  list(date = format(d$match_date[i], "%d %b %Y"), season = d$season[i],
       winner = d$winner[i],
       loser = ifelse(d$winner[i] == d$team1[i], d$team2[i], d$team1[i]),
       venue = d$venue[i], win_prob = round(sort(p_winner)[j] * 100, 1))
})

# ----------------------------------------------------------- ratings for UI
last_season <- max(d$season)
active <- sort(unique(c(d$team1[d$season == last_season], d$team2[d$season == last_season])))
current <- lapply(teams, function(t) list(
  team = t, elo = round(unname(elo[t]), 1), form = round(form_of(t), 3),
  active = t %in% active
))
current <- current[order(-sapply(current, `[[`, "elo"))]

hist_seasons <- as.integer(names(history))
played_in <- function(t, s) any(d$season == s & (d$team1 == t | d$team2 == t))
elo_history <- lapply(teams, function(t) list(
  team = t,
  ratings = lapply(hist_seasons, function(s)
    if (played_in(t, s)) round(unname(history[[as.character(s)]][t]), 1) else NULL)
))

out <- list(
  generated = format(Sys.time(), "%Y-%m-%d %H:%M"),
  r_version = R.version.string,
  settings = list(k = K, start = START, carry = CARRY, form_n = FORM_N),
  current = current,
  history = list(seasons = hist_seasons, teams = elo_history),
  coefficients = coefficients,
  evaluation = evaluation,
  calibration = calibration,
  upsets = upsets,
  aic = round(AIC(fit), 1), n_matches = nrow(dm)
)
writeLines(toJSON(out, auto_unbox = TRUE, null = "null", digits = NA, pretty = TRUE), out_file)
cat(sprintf("Wrote %s  (%d matches, test accuracy %.1f%%)\n",
            out_file, nrow(dm), evaluation$model$accuracy))
