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
export interface Analysis {
  best: JointMove | null; advantage: number | null; mate: number | null;
  calibration: { source: 'measured' | 'unavailable' | 'pending' };
  nodes: number; total_nodes?: number; elapsed_ms?: number; cached?: boolean;
  lines: { best: JointMove | null }[];
}
export interface EnginePayload {
  dual_fen?: string | null; moves?: string[]; team?: Colour;
  time_advantage?: boolean; their_time_advantage?: boolean;
  require_move_on?: string; movetime_ms?: number; nodes?: number;
}
export type EngineAction = 'position' | 'analyse' | 'search';
export interface EngineReply {
  id?: number; progress?: string; error?: string; result?: unknown; partial?: Analysis;
}
