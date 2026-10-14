/** Shared browser/worker protocol. Board letters name boards, not player seats. */
export type BoardName = 'A' | 'B';
export type Colour = 'white' | 'black';
export interface Move { uci: string; san: string }
export interface Board {
  fen: string; pieces: Record<string, string>; turn: Colour; we_play: Colour;
  pockets: Record<Colour, string>; legal_moves: Move[]; movetext: string; check: boolean;
}
export interface Position { dual_fen: string; boards: Record<BoardName, Board> }
export interface JointMove { A: string; B: string; uci: string }
export interface RawEvaluation { q: number; mate: number | null; nodes: number; best: JointMove | null; pv?: string[] }
export interface Analysis {
  best: JointMove | null; advantage: number | null; mate: number | null;
  calibration: { source: 'measured' | 'static' | 'unavailable' | 'pending' };
  raw?: { ours: RawEvaluation; theirs: RawEvaluation | null; static_values?: number[] };
  shared?: boolean;
  nodes: number; total_nodes?: number; elapsed_ms?: number; cached?: boolean;
  lines: { best: JointMove | null }[];
}
export interface EnginePayload {
  dual_fen?: string | null; moves?: string[]; team?: Colour;
  time_advantage?: boolean; their_time_advantage?: boolean;
  require_move_on?: string; movetime_ms?: number; nodes?: number;
  /** `frozen`: one board's FEN, its engine lines, and how often (ms) to report while searching. */
  fen?: string; lines?: number; report_ms?: number;
}
export type EngineAction = 'position' | 'analyse' | 'search' | 'frozen';
/**
 * `frozen` reports and result: board A searched with the partner board held
 * still (Bughouse Single Board). Values are from the side to move; mate is in
 * plies. The first report carries only `static`, the network's own score.
 */
export interface FrozenSearch {
  static?: number;
  q: number; mate: number | null; nodes: number; depth: number; elapsed_ms: number; offset: number; done: boolean;
  lines: { q: number; mate: number | null; visits: number; prior: number; pv: string[] }[];
}
export interface EngineReply {
  id?: number; progress?: string; error?: string; result?: unknown; partial?: Analysis | FrozenSearch;
}
