import '../models/section_configuration.dart';

abstract interface class SettingsSectionStorage<
  C extends SectionConfiguration<C>
> {
  Future<C> read();
  Future<void> write(SettingsPatch<C> patch);
}
