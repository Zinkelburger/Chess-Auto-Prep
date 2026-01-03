/**
 * Test script to analyze evaluation format differences between Flutter and Web
 * This script examines the raw evaluation logic without needing the browser
 */

// Simulate the web app's evaluation normalization
function simulateWebNormalization(rawEval, fen, userColor) {
  console.log('\n=== Web App Normalization Simulation ===');
  console.log('Raw eval from engine:', rawEval);
  console.log('FEN:', fen);
  console.log('User color:', userColor);

  // Convert to centipawns (web multiplies by 100)
  const rawCp = rawEval * 100;
  console.log('Raw CP (eval * 100):', rawCp);

  // Determine whose turn it is
  const parts = fen.split(' ');
  const isWhiteTurn = parts[1] === 'w';
  console.log('Is White Turn:', isWhiteTurn);

  // First normalization: to White's perspective
  const cpWhitePerspective = isWhiteTurn ? rawCp : -rawCp;
  console.log('CP White Perspective:', cpWhitePerspective);

  // Second normalization: to User's perspective
  let cpUserPerspective = cpWhitePerspective;
  if (userColor === 'b') {
    cpUserPerspective = -cpWhitePerspective;
  }
  console.log('CP User Perspective:', cpUserPerspective);

  return {
    rawCp,
    isWhiteTurn,
    cpWhitePerspective,
    cpUserPerspective
  };
}

// Simulate Flutter's evaluation normalization (based on stockfish_service.dart)
function simulateFlutterNormalization(rawEval, fen) {
  console.log('\n=== Flutter Normalization Simulation ===');
  console.log('Raw eval from engine:', rawEval);
  console.log('FEN:', fen);

  // Flutter's logic (from stockfish_service.dart lines 120-124)
  const parts = fen.split(' ');
  const isWhiteTurn = parts[1] === 'w';
  console.log('Is White Turn:', isWhiteTurn);

  // Flutter normalizes score to White's perspective directly
  // scoreCp = _isWhiteTurn ? val : -val;
  const normalizedCp = isWhiteTurn ? rawEval : -rawEval;
  console.log('Normalized CP (White perspective):', normalizedCp);

  return {
    isWhiteTurn,
    normalizedCp
  };
}

// Test winning chances calculation
function testWinningChances() {
  console.log('\n=== Winning Chances Formula Test ===');

  const MULTIPLIER = -0.00368208;
  function winningChances(centipawns) {
    const capped = Math.max(-1000, Math.min(1000, centipawns));
    return 2 / (1 + Math.exp(MULTIPLIER * capped)) - 1;
  }

  const testValues = [0, 50, 100, 200, 300, 500, -50, -100, -200, -300];

  testValues.forEach(cp => {
    const wc = winningChances(cp);
    const winPercent = 50 + 50 * wc;
    console.log(`${cp}cp -> WC: ${wc.toFixed(3)} -> Win%: ${winPercent.toFixed(1)}%`);
  });
}

// Test specific scenarios that might reveal the issue
function testScenarios() {
  console.log('\n' + '='.repeat(60));
  console.log('TESTING EVALUATION FORMAT SCENARIOS');
  console.log('='.repeat(60));

  // Scenario 1: Starting position, White to move
  console.log('\n--- SCENARIO 1: Starting Position, White to move ---');
  const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  const startEval = 0.15; // Typical slight White advantage

  const webStart = simulateWebNormalization(startEval, startFen, 'w');
  const flutterStart = simulateFlutterNormalization(startEval * 100, startFen); // Flutter uses centipawns

  console.log('\nComparison:');
  console.log('Web User Perspective:', webStart.cpUserPerspective);
  console.log('Flutter White Perspective:', flutterStart.normalizedCp);

  // Scenario 2: Same position, but Black to move after e4
  console.log('\n--- SCENARIO 2: After 1.e4, Black to move ---');
  const afterE4Fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
  const afterE4Eval = 0.25; // White advantage

  const webE4 = simulateWebNormalization(afterE4Eval, afterE4Fen, 'b'); // Black user
  const flutterE4 = simulateFlutterNormalization(afterE4Eval * 100, afterE4Fen);

  console.log('\nComparison (Black user):');
  console.log('Web User Perspective:', webE4.cpUserPerspective);
  console.log('Flutter White Perspective:', flutterE4.normalizedCp);

  // Scenario 3: Test a typical blunder detection
  console.log('\n--- SCENARIO 3: Blunder Detection Test ---');

  const beforeFen = 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
  const afterFen = 'rnbqkbnr/pppp1ppp/8/4p2Q/4P3/8/PPPP1PPP/RNBQK1NR b KQkq - 1 2';

  const evalBefore = 0.2; // Slight White advantage
  const evalAfter = -4.5; // Black winning after hanging queen

  console.log('\nBefore move (White advantage):');
  const webBefore = simulateWebNormalization(evalBefore, beforeFen, 'w');
  const flutterBefore = simulateFlutterNormalization(evalBefore * 100, beforeFen);

  console.log('\nAfter move (Black advantage):');
  const webAfter = simulateWebNormalization(evalAfter, afterFen, 'w');
  const flutterAfter = simulateFlutterNormalization(evalAfter * 100, afterFen);

  // Calculate deltas
  const webDelta = webBefore.cpUserPerspective - webAfter.cpUserPerspective;
  const flutterDelta = flutterBefore.normalizedCp - flutterAfter.normalizedCp;

  console.log('\nDelta comparison:');
  console.log('Web delta:', webDelta, 'cp');
  console.log('Flutter delta:', flutterDelta, 'cp');

  // Convert to winning chances
  const MULTIPLIER = -0.00368208;
  function winningChances(cp) {
    const capped = Math.max(-1000, Math.min(1000, cp));
    return 2 / (1 + Math.exp(MULTIPLIER * capped)) - 1;
  }

  const webWcBefore = winningChances(webBefore.cpUserPerspective);
  const webWcAfter = winningChances(webAfter.cpUserPerspective);
  const webWcDelta = webWcBefore - webWcAfter;

  console.log('\nWeb winning chances:');
  console.log('Before:', webWcBefore.toFixed(3), 'After:', webWcAfter.toFixed(3), 'Delta:', webWcDelta.toFixed(3));
  console.log('Classification:', webWcDelta >= 0.3 ? 'BLUNDER' : (webWcDelta >= 0.2 ? 'MISTAKE' : 'OK'));
}

// Main test runner
function runTests() {
  console.log('🔬 EVALUATION FORMAT ANALYSIS');
  console.log('Testing differences between Web and Flutter evaluation normalization');

  testWinningChances();
  testScenarios();

  console.log('\n💡 POTENTIAL ISSUES TO INVESTIGATE:');
  console.log('1. Web does double normalization (White perspective -> User perspective)');
  console.log('2. Flutter only normalizes to White perspective');
  console.log('3. Different units: Web uses eval*100, Flutter uses raw centipawns');
  console.log('4. Sign handling might be inconsistent between platforms');
  console.log('5. Winning chances calculation might differ');
}

// Run the tests
runTests();