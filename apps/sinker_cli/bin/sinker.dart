import 'package:sinker_cli/src/cli_app.dart';

Future<void> main(List<String> args) async {
  final app = CliApp();

  try {
    await app.run(args);
  } catch (e) {
    print('Error: $e');
  }
}
