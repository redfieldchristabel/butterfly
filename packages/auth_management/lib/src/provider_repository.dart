abstract interface class AuthServiceProviderRepository<T>
    implements AuthServiceRepository<T> {
  FutureOr<void> bindUserToProvider(T user);
}
