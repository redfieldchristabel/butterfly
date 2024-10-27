// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'main.dart';

// **************************************************************************
// _IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, invalid_use_of_protected_member, lines_longer_than_80_chars, constant_identifier_names, avoid_js_rounded_ints, no_leading_underscores_for_local_identifiers, require_trailing_commas, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_in_if_null_operators, library_private_types_in_public_api, prefer_const_constructors
// ignore_for_file: type=lint

extension GetMyUserCollection on Isar {
  IsarCollection<int, MyUser> get myUsers => this.collection();
}

const MyUserSchema = IsarGeneratedSchema(
  schema: IsarSchema(
    name: 'MyUser',
    idName: 'id',
    embedded: false,
    properties: [],
    indexes: [],
  ),
  converter: IsarObjectConverter<int, MyUser>(
    serialize: serializeMyUser,
    deserialize: deserializeMyUser,
    deserializeProperty: deserializeMyUserProp,
  ),
  embeddedSchemas: [],
);

@isarProtected
int serializeMyUser(IsarWriter writer, MyUser object) {
  return object.id;
}

@isarProtected
MyUser deserializeMyUser(IsarReader reader) {
  final int _id;
  _id = IsarCore.readId(reader);
  final object = MyUser(
    id: _id,
  );
  return object;
}

@isarProtected
dynamic deserializeMyUserProp(IsarReader reader, int property) {
  switch (property) {
    case 0:
      return IsarCore.readId(reader);
    default:
      throw ArgumentError('Unknown property: $property');
  }
}

extension MyUserQueryFilter on QueryBuilder<MyUser, MyUser, QFilterCondition> {
  QueryBuilder<MyUser, MyUser, QAfterFilterCondition> idEqualTo(
    int value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        EqualCondition(
          property: 0,
          value: value,
        ),
      );
    });
  }

  QueryBuilder<MyUser, MyUser, QAfterFilterCondition> idGreaterThan(
    int value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        GreaterCondition(
          property: 0,
          value: value,
        ),
      );
    });
  }

  QueryBuilder<MyUser, MyUser, QAfterFilterCondition> idGreaterThanOrEqualTo(
    int value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        GreaterOrEqualCondition(
          property: 0,
          value: value,
        ),
      );
    });
  }

  QueryBuilder<MyUser, MyUser, QAfterFilterCondition> idLessThan(
    int value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        LessCondition(
          property: 0,
          value: value,
        ),
      );
    });
  }

  QueryBuilder<MyUser, MyUser, QAfterFilterCondition> idLessThanOrEqualTo(
    int value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        LessOrEqualCondition(
          property: 0,
          value: value,
        ),
      );
    });
  }

  QueryBuilder<MyUser, MyUser, QAfterFilterCondition> idBetween(
    int lower,
    int upper,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        BetweenCondition(
          property: 0,
          lower: lower,
          upper: upper,
        ),
      );
    });
  }
}

extension MyUserQueryObject on QueryBuilder<MyUser, MyUser, QFilterCondition> {}

extension MyUserQuerySortBy on QueryBuilder<MyUser, MyUser, QSortBy> {
  QueryBuilder<MyUser, MyUser, QAfterSortBy> sortById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0);
    });
  }

  QueryBuilder<MyUser, MyUser, QAfterSortBy> sortByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0, sort: Sort.desc);
    });
  }
}

extension MyUserQuerySortThenBy on QueryBuilder<MyUser, MyUser, QSortThenBy> {
  QueryBuilder<MyUser, MyUser, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0);
    });
  }

  QueryBuilder<MyUser, MyUser, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0, sort: Sort.desc);
    });
  }
}

extension MyUserQueryWhereDistinct on QueryBuilder<MyUser, MyUser, QDistinct> {}

extension MyUserQueryProperty1 on QueryBuilder<MyUser, MyUser, QProperty> {
  QueryBuilder<MyUser, int, QAfterProperty> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addProperty(0);
    });
  }
}

extension MyUserQueryProperty2<R> on QueryBuilder<MyUser, R, QAfterProperty> {
  QueryBuilder<MyUser, (R, int), QAfterProperty> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addProperty(0);
    });
  }
}

extension MyUserQueryProperty3<R1, R2>
    on QueryBuilder<MyUser, (R1, R2), QAfterProperty> {
  QueryBuilder<MyUser, (R1, R2, int), QOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addProperty(0);
    });
  }
}
