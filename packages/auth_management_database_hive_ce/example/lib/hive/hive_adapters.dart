import 'package:auth_management_database_hive_ce_example/main.dart';
import 'package:hive_ce/hive.dart';

part 'hive_adapters.g.dart';

@GenerateAdapters([AdapterSpec<User>()])
// Annotations must be on some element
// ignore: unused_element
void _() {}