import 'maia_factory.dart';
import 'maia_service.dart';

/// Native implementation - uses ONNX runtime
bool get isMaiaAvailable => true;

MaiaEvaluator? createMaiaEvaluator() => _NativeMaiaEvaluator();

class _NativeMaiaEvaluator implements MaiaEvaluator {
  final _maiaService = MaiaService();
  
  @override
  Future<void> initialize() => _maiaService.initialize();
  
  @override
  Future<Map<String, double>> evaluate(String fen, int elo) => 
      _maiaService.evaluate(fen, elo);
  
  @override
  void dispose() => _maiaService.dispose();
}


