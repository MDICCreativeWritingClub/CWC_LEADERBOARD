"use client";

import { useEffect, useMemo, useState } from "react";
import { CheckCircle, Save } from "lucide-react";
import { colors } from "@/lib/theme";
import { staffSupabase } from "@/lib/staffSupabase";
import { useAuth } from "@/context/AuthContext";
import { useSubmissions } from "@/context/SubmissionsContext";
import { inputStyle } from "./shared";

const CATEGORIES = [
  { key: "theme", label: "Theme" },
  { key: "writing", label: "Writing" },
  { key: "voice", label: "Voice" },
  { key: "structure", label: "Structure" },
] as const;

type Category = (typeof CATEGORIES)[number]["key"];
type Scores = Record<Category, number>;
type Draft = Record<Category, string>;

const EMPTY_DRAFT: Draft = { theme: "", writing: "", voice: "", structure: "" };

function toDraft(scores: Scores): Draft {
  return {
    theme: String(scores.theme),
    writing: String(scores.writing),
    voice: String(scores.voice),
    structure: String(scores.structure),
  };
}

/** YYYY-MM of an ISO timestamp, in Dhaka time. */
function dhakaMonth(iso: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka", year: "numeric", month: "2-digit" }).format(new Date(iso));
}

function monthLabel(key: string): string {
  const [y, m] = key.split("-").map(Number);
  return new Date(y, m - 1, 1).toLocaleString("en-GB", { month: "long", year: "numeric" });
}

interface StandingRow {
  rank: number;
  article_id: string;
  title: string;
  writer_name: string;
  judges: number;
  avg_theme: number | null;
  avg_writing: number | null;
  avg_voice: number | null;
  avg_structure: number | null;
  judge_score: number | null;
  valid_votes: number;
  vote_points: number;
  points: number | null;
}

function fmt(n: number | null | undefined): string {
  return n === null || n === undefined ? "—" : String(Number(n));
}

function Standings() {
  const [rows, setRows] = useState<StandingRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    const { data, error: rpcError } = await staffSupabase.rpc("get_leaderboard_staff");
    if (rpcError) {
      setError("Couldn't load the standings.");
    } else {
      setRows((data ?? []) as StandingRow[]);
      setError(null);
    }
    setLoading(false);
  }

  useEffect(() => {
    load();
  }, []);

  const th: React.CSSProperties = { color: colors.gray500, fontSize: "0.7rem", fontWeight: 500, textAlign: "right", padding: "0.5rem 0.6rem", whiteSpace: "nowrap" };
  const td: React.CSSProperties = { color: colors.gray700, fontSize: "0.8rem", textAlign: "right", padding: "0.55rem 0.6rem", whiteSpace: "nowrap" };

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <p style={{ color: colors.gray500, fontSize: "0.8rem" }}>
          Averages across all judges. Votes count only unflagged votes.
        </p>
        <button
          onClick={load}
          disabled={loading}
          className="px-4 py-1.5 rounded-full text-xs transition-all active:scale-95 disabled:opacity-50"
          style={{ backgroundColor: colors.gray100, color: colors.gray700 }}
        >
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </div>
      {error && <p style={{ color: colors.red600, fontSize: "0.8rem" }}>{error}</p>}
      <div className="overflow-x-auto rounded-xl border" style={{ borderColor: colors.gray200, backgroundColor: colors.surface }}>
        <table className="w-full" style={{ borderCollapse: "collapse" }}>
          <thead>
            <tr style={{ borderBottom: `1px solid ${colors.gray200}` }}>
              <th style={{ ...th, textAlign: "left" }}>#</th>
              <th style={{ ...th, textAlign: "left" }}>Writing</th>
              <th style={th}>Judges</th>
              <th style={th}>Theme</th>
              <th style={th}>Writing</th>
              <th style={th}>Voice</th>
              <th style={th}>Structure</th>
              <th style={th}>Judge total</th>
              <th style={th}>Votes</th>
              <th style={th}>Vote pts</th>
              <th style={th}>Points</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && !loading && (
              <tr>
                <td colSpan={11} style={{ ...td, textAlign: "center", color: colors.gray400, padding: "1.5rem" }}>No approved writings yet.</td>
              </tr>
            )}
            {rows.map((r) => (
              <tr key={r.article_id} style={{ borderBottom: `1px solid ${colors.gray100}` }}>
                <td style={{ ...td, textAlign: "left" }}>{r.rank}</td>
                <td style={{ ...td, textAlign: "left", whiteSpace: "normal", minWidth: "12rem" }}>
                  <span style={{ color: colors.heading, fontWeight: 500 }}>{r.title}</span>
                  <br />
                  <span style={{ color: colors.gray400, fontSize: "0.7rem" }}>{r.writer_name}</span>
                </td>
                <td style={td}>{r.judges}</td>
                <td style={td}>{fmt(r.avg_theme)}</td>
                <td style={td}>{fmt(r.avg_writing)}</td>
                <td style={td}>{fmt(r.avg_voice)}</td>
                <td style={td}>{fmt(r.avg_structure)}</td>
                <td style={td}>{fmt(r.judge_score)}</td>
                <td style={td}>{r.valid_votes}</td>
                <td style={td}>{fmt(r.vote_points)}</td>
                <td style={{ ...td, color: colors.heading, fontWeight: 700 }}>{fmt(r.points)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export function ScoringTab() {
  const { identity } = useAuth();
  const { submissions } = useSubmissions();
  const staffUserId = identity?.kind === "staff" ? identity.userId : null;

  const [view, setView] = useState<"score" | "standings">("score");
  const [monthKey, setMonthKey] = useState<string>(() => dhakaMonth(new Date().toISOString()));
  const [mine, setMine] = useState<Record<string, Scores>>({});
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [saving, setSaving] = useState<string | null>(null);
  const [savedId, setSavedId] = useState<string | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [loadError, setLoadError] = useState<string | null>(null);

  // This judge's own saved scores.
  useEffect(() => {
    if (!staffUserId) return;
    let cancelled = false;
    staffSupabase
      .from("article_scores")
      .select("article_id, theme, writing, voice, structure")
      .eq("judge_id", staffUserId)
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) {
          setLoadError("Couldn't load your saved scores.");
          return;
        }
        const map: Record<string, Scores> = {};
        for (const row of data ?? []) {
          map[row.article_id as string] = {
            theme: row.theme as number,
            writing: row.writing as number,
            voice: row.voice as number,
            structure: row.structure as number,
          };
        }
        setMine(map);
        setLoadError(null);
      });
    return () => {
      cancelled = true;
    };
  }, [staffUserId]);

  const approved = useMemo(
    () =>
      submissions
        .filter((s) => s.status === "approved")
        .sort((a, b) => b.submittedAt.localeCompare(a.submittedAt)),
    [submissions]
  );

  const months = useMemo(() => {
    const set = new Set(approved.map((s) => dhakaMonth(s.submittedAt)));
    set.add(dhakaMonth(new Date().toISOString()));
    return Array.from(set).sort().reverse();
  }, [approved]);

  const visible = approved.filter((s) => monthKey === "all" || dhakaMonth(s.submittedAt) === monthKey);

  function draftFor(id: string): Draft {
    return drafts[id] ?? (mine[id] ? toDraft(mine[id]) : EMPTY_DRAFT);
  }

  function setField(id: string, key: Category, value: string) {
    setDrafts((prev) => ({ ...prev, [id]: { ...draftFor(id), [key]: value } }));
    setErrors((prev) => ({ ...prev, [id]: "" }));
  }

  function parseDraft(d: Draft): Scores | null {
    const out = {} as Scores;
    for (const { key } of CATEGORIES) {
      const raw = d[key].trim();
      const n = Number(raw);
      if (raw === "" || !Number.isInteger(n) || n < 0 || n > 20) return null;
      out[key] = n;
    }
    return out;
  }

  async function save(id: string) {
    const scores = parseDraft(draftFor(id));
    if (!scores) {
      setErrors((prev) => ({ ...prev, [id]: "Enter a whole number from 0 to 20 in every category." }));
      return;
    }
    setSaving(id);
    const { error } = await staffSupabase.rpc("save_article_score", {
      p_article_id: id,
      p_theme: scores.theme,
      p_writing: scores.writing,
      p_voice: scores.voice,
      p_structure: scores.structure,
    });
    setSaving(null);
    if (error) {
      const msg = error.message?.includes("NOT_AUTHORIZED")
        ? "Your account can't score writings."
        : "Couldn't save this score. Try again.";
      setErrors((prev) => ({ ...prev, [id]: msg }));
      return;
    }
    setMine((prev) => ({ ...prev, [id]: scores }));
    setDrafts((prev) => {
      const next = { ...prev };
      delete next[id];
      return next;
    });
    setSavedId(id);
    window.setTimeout(() => setSavedId((cur) => (cur === id ? null : cur)), 2500);
  }

  return (
    <div className="max-w-5xl flex flex-col gap-5">
      <div className="flex gap-2">
        {([["score", "Score writings"], ["standings", "Standings"]] as const).map(([key, label]) => (
          <button
            key={key}
            onClick={() => setView(key)}
            className="px-4 py-1.5 rounded-full text-sm transition-all active:scale-95"
            style={{
              backgroundColor: view === key ? colors.green900 : colors.gray100,
              color: view === key ? colors.white : colors.gray700,
            }}
          >
            {label}
          </button>
        ))}
      </div>

      {view === "standings" ? (
        <Standings />
      ) : (
        <>
          <div className="rounded-xl p-4 border" style={{ backgroundColor: colors.yellow50, borderColor: colors.amber200 }}>
            <p style={{ color: colors.amber800, fontSize: "0.8rem" }}>
              Score each approved writing from 0 to 20 (whole numbers) in Theme, Writing, Voice and Structure. Your scores are private to you; the standings average every judge. You can change a score at any time.
            </p>
          </div>

          <div className="flex items-center gap-3">
            <label style={{ color: colors.gray700, fontSize: "0.8rem", fontWeight: 500 }} htmlFor="score-month">Month</label>
            <select
              id="score-month"
              style={{ ...inputStyle, width: "auto", color: colors.gray900 }}
              value={monthKey}
              onChange={(e) => setMonthKey(e.target.value)}
            >
              {months.map((m) => (
                <option key={m} value={m}>{monthLabel(m)}</option>
              ))}
              <option value="all">All months</option>
            </select>
            <span style={{ color: colors.gray400, fontSize: "0.75rem" }}>
              {visible.filter((s) => mine[s.id]).length} of {visible.length} scored by you
            </span>
          </div>

          {loadError && <p style={{ color: colors.red600, fontSize: "0.8rem" }}>{loadError}</p>}

          {visible.length === 0 ? (
            <div className="text-center py-16" style={{ color: colors.gray400 }}>
              No approved writings in this period.
            </div>
          ) : (
            <div className="flex flex-col gap-4">
              {visible.map((sub) => {
                const d = draftFor(sub.id);
                const parsed = parseDraft(d);
                const total = parsed ? parsed.theme + parsed.writing + parsed.voice + parsed.structure : null;
                return (
                  <div
                    key={sub.id}
                    className="rounded-2xl border p-5"
                    style={{ borderColor: mine[sub.id] ? colors.green200 : colors.gray200, backgroundColor: colors.surface }}
                  >
                    <div className="flex items-start justify-between gap-3 mb-4">
                      <div className="min-w-0">
                        <h3 style={{ color: colors.heading, fontWeight: 600, fontSize: "1rem" }}>{sub.title}</h3>
                        <p style={{ color: colors.gray500, fontSize: "0.75rem" }}>{sub.name} · {sub.grade} · {sub.category}</p>
                      </div>
                      {mine[sub.id] && (
                        <span
                          className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs shrink-0"
                          style={{ backgroundColor: colors.badgeBg, color: colors.badgeText, border: `1px solid ${colors.badgeBorder}` }}
                        >
                          <CheckCircle size={12} /> Scored
                        </span>
                      )}
                    </div>

                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
                      {CATEGORIES.map(({ key, label }) => (
                        <div key={key}>
                          <label
                            htmlFor={`${sub.id}-${key}`}
                            style={{ color: colors.gray700, fontSize: "0.8rem", fontWeight: 500, display: "block", marginBottom: "0.4rem" }}
                          >
                            {label} <span style={{ color: colors.gray400, fontWeight: 400 }}>/ 20</span>
                          </label>
                          <input
                            id={`${sub.id}-${key}`}
                            type="number"
                            inputMode="numeric"
                            min={0}
                            max={20}
                            step={1}
                            style={inputStyle}
                            value={d[key]}
                            onChange={(e) => setField(sub.id, key, e.target.value)}
                          />
                        </div>
                      ))}
                    </div>

                    <div className="flex items-center gap-3 flex-wrap">
                      <button
                        onClick={() => save(sub.id)}
                        disabled={saving === sub.id}
                        className="flex items-center gap-2 px-5 py-2 rounded-xl text-sm text-white hover:opacity-90 transition-opacity disabled:opacity-50"
                        style={{ backgroundColor: colors.green900 }}
                      >
                        <Save size={14} /> {saving === sub.id ? "Saving…" : "Save score"}
                      </button>
                      {total !== null && (
                        <span style={{ color: colors.gray500, fontSize: "0.8rem" }}>Your total: {total} / 80</span>
                      )}
                      {savedId === sub.id && <span style={{ color: colors.green700, fontSize: "0.8rem" }}>Score saved</span>}
                    </div>
                    {errors[sub.id] && (
                      <p style={{ color: colors.red600, fontSize: "0.8rem", marginTop: "0.5rem" }}>{errors[sub.id]}</p>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </>
      )}
    </div>
  );
}
