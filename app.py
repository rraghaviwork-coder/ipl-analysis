"""IPL Match Analysis — Flask backend.

Run:  python app.py   then open http://localhost:5000
"""
import os

import pandas as pd
from flask import Flask, jsonify, render_template, request

DATA_URL = "https://raw.githubusercontent.com/ritesh-ojha/IPL-DATASET/main/csv/Match_Info.csv"
LOCAL_FILE = os.path.join(os.path.dirname(__file__), "data", "matches.csv")

# Franchises that were renamed -> current name
TEAM_RENAMES = {
    "Delhi Daredevils": "Delhi Capitals",
    "Kings XI Punjab": "Punjab Kings",
    "Royal Challengers Bangalore": "Royal Challengers Bengaluru",
    "Rising Pune Supergiants": "Rising Pune Supergiant",
}

TEAM_INFO = {  # short code, brand colour
    "Chennai Super Kings": ("CSK", "#F2B705"),
    "Mumbai Indians": ("MI", "#004BA0"),
    "Royal Challengers Bengaluru": ("RCB", "#C8102E"),
    "Kolkata Knight Riders": ("KKR", "#3A225D"),
    "Sunrisers Hyderabad": ("SRH", "#F26522"),
    "Rajasthan Royals": ("RR", "#E2338A"),
    "Delhi Capitals": ("DC", "#2561AE"),
    "Punjab Kings": ("PBKS", "#E8515D"),
    "Gujarat Titans": ("GT", "#1C2C5B"),
    "Lucknow Super Giants": ("LSG", "#2ABFE3"),
    "Deccan Chargers": ("DCG", "#7D8B99"),
    "Gujarat Lions": ("GL", "#E46A23"),
    "Pune Warriors": ("PWI", "#3FA9F5"),
    "Rising Pune Supergiant": ("RPS", "#8E44AD"),
    "Kochi Tuskers Kerala": ("KTK", "#A0522D"),
}


def load_data():
    df = pd.read_csv(LOCAL_FILE if os.path.exists(LOCAL_FILE) else DATA_URL)
    for col in ["team1", "team2", "toss_winner", "winner", "eliminator"]:
        df[col] = df[col].replace(TEAM_RENAMES)
    # Tied matches have no winner; the super-over winner is in 'eliminator'
    df["winner"] = df["winner"].fillna(df["eliminator"])
    df["match_date"] = pd.to_datetime(df["match_date"])
    df["season"] = df["match_date"].dt.year
    df["city"] = df["city"].fillna("Unknown")
    # Who batted first? Toss winner if they chose to bat, otherwise the other team
    other = df["team2"].where(df["toss_winner"] == df["team1"], df["team1"])
    df["bat_first"] = df["toss_winner"].where(df["toss_decision"] == "bat", other)
    return df.sort_values("match_date").reset_index(drop=True)


DF = load_data()
SEASONS = sorted(DF["season"].unique().tolist())
TEAMS = sorted(set(DF["team1"]) | set(DF["team2"]))

app = Flask(__name__)


def season_filtered():
    lo = request.args.get("from", SEASONS[0], type=int)
    hi = request.args.get("to", SEASONS[-1], type=int)
    return DF[DF["season"].between(min(lo, hi), max(lo, hi))]


def top_counts(series, n=10):
    vc = series.value_counts().head(n)
    return [{"label": k, "value": int(v)} for k, v in vc.items()]


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/meta")
def meta():
    return jsonify(seasons=SEASONS, teams=TEAMS,
                   info={t: {"short": s, "color": c} for t, (s, c) in TEAM_INFO.items()})


@app.route("/api/summary")
def summary():
    d = season_filtered()
    decided = d[d["winner"].notna()]

    # Team records
    played = pd.concat([d["team1"], d["team2"]]).value_counts()
    wins = decided["winner"].value_counts().reindex(played.index, fill_value=0)
    teams = [{"team": t, "played": int(played[t]), "wins": int(wins[t]),
              "pct": round(wins[t] / played[t] * 100, 1)} for t in played.index]
    teams.sort(key=lambda r: r["wins"], reverse=True)

    # Champions: the last match of each season is the final
    finals = d.groupby("season").tail(1)
    champions = [{"season": int(r.season), "champion": r.winner,
                  "runner_up": r.team2 if r.winner == r.team1 else r.team1,
                  "venue": r.venue, "potm": r.player_of_match}
                 for r in finals.itertuples() if pd.notna(r.winner)]
    titles = pd.Series([c["champion"] for c in champions]).value_counts()

    # Toss
    toss_won_match = int((decided["toss_winner"] == decided["winner"]).sum())
    trend = d.groupby(["season", "toss_decision"]).size().unstack(fill_value=0)

    # Batting first vs chasing
    bf_wins = int((decided["winner"] == decided["bat_first"]).sum())
    chase_by_season = (decided.assign(chased=decided["winner"] != decided["bat_first"])
                       .groupby("season")["chased"].mean().mul(100).round(1))

    return jsonify(
        kpis={"matches": len(d), "seasons": int(d["season"].nunique()),
              "venues": int(d["venue"].nunique()), "teams": int(played.size),
              "most_titles": titles[titles == titles.max()].index.tolist() if len(titles) else [],
              "most_titles_n": int(titles.iloc[0]) if len(titles) else 0,
              "chase_pct": round((len(decided) - bf_wins) / max(len(decided), 1) * 100, 1)},
        teams=teams,
        per_season=[{"season": int(s), "matches": int(n)} for s, n in d.groupby("season").size().items()],
        champions=champions,
        titles=[{"label": k, "value": int(v)} for k, v in titles.items()],
        toss={"bat": int((d["toss_decision"] == "bat").sum()),
              "field": int((d["toss_decision"] == "field").sum()),
              "won_match": toss_won_match, "lost_match": len(decided) - toss_won_match,
              "trend": {"seasons": trend.index.tolist(),
                        "bat": trend.get("bat", pd.Series(0, trend.index)).tolist(),
                        "field": trend.get("field", pd.Series(0, trend.index)).tolist()}},
        chase={"bat_first_wins": bf_wins, "chase_wins": len(decided) - bf_wins,
               "seasons": chase_by_season.index.tolist(), "pct": chase_by_season.tolist()},
        potm=top_counts(d["player_of_match"]),
        cities=top_counts(d["city"]),
        venues=top_counts(d["venue"], 8),
    )


@app.route("/api/h2h")
def h2h():
    d = season_filtered()
    a, b = request.args.get("a"), request.args.get("b")
    m = d[((d["team1"] == a) & (d["team2"] == b)) | ((d["team1"] == b) & (d["team2"] == a))]
    rows = [{"date": r.match_date.strftime("%d %b %Y"), "venue": r.venue, "city": r.city,
             "winner": r.winner if pd.notna(r.winner) else "No result",
             "toss": f"{r.toss_winner} chose to {r.toss_decision}",
             "potm": r.player_of_match if pd.notna(r.player_of_match) else "-"}
            for r in m.iloc[::-1].itertuples()]
    return jsonify(matches=len(m), a_wins=int((m["winner"] == a).sum()),
                   b_wins=int((m["winner"] == b).sum()), no_result=int(m["winner"].isna().sum()),
                   rows=rows)


if __name__ == "__main__":
    app.run(debug=True)
