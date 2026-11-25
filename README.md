# IPL Match Analysis Dashboard

A web dashboard analysing every IPL match from 2008 to 2026.

**Tech stack:** Python · Flask (web server + JSON API) · Pandas (analysis) · HTML/CSS + Chart.js (frontend)

## Features
- **Champions timeline:** winner, runner-up and final's Player of the Match for every season
- **Team performance:** total wins, win %, titles won, matches per season
- **Toss & strategy:** bat vs field choice, whether the toss winner wins, batting first vs chasing, trends by season
- **Head to head:** pick any two teams to see their record and every match between them
- **Players & venues:** most Player of the Match awards, top host cities
- A season range filter that updates the whole page

## Project structure
```
app.py               Flask backend: loads data, computes stats with Pandas, serves /api/*
templates/index.html Page layout
static/style.css     Styling (responsive)
static/app.js        Fetches the API and draws the charts with Chart.js
data/matches.csv     Dataset (downloaded automatically if missing)
```

## Dataset
IPL match-level data based on Cricsheet: https://github.com/ritesh-ojha/IPL-DATASET (`csv/Match_Info.csv`).
Renamed franchises are merged into their current names (e.g. Delhi Daredevils → Delhi Capitals).
In tied matches, the super-over winner counts as the winner.
The champion is the winner of each season's last match (the final).

## How to run
```bash
pip install -r requirements.txt
python app.py
```
Open http://localhost:5000
