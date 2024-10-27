// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'base_user_model.dart';

// **************************************************************************
// _IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, invalid_use_of_protected_member, lines_longer_than_80_chars, constant_identifier_names, avoid_js_rounded_ints, no_leading_underscores_for_local_identifiers, require_trailing_commas, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_in_if_null_operators, library_private_types_in_public_api, prefer_const_constructors
// ignore_for_file: type=lint

extension GetBaseUserCollection on Isar {
  IsarCollection<int, BaseUser> get baseUsers => this.collection();
}

const BaseUserSchema = IsarGeneratedSchema(
  schema: IsarSchema(
    name: 'BaseUser',
    idName: 'id',
    embedded: false,
    properties: [],
    indexes: [],
  ),
  converter: IsarObjectConverter<int, BaseUser>(
    serialize: serializeBaseUser,
    deserialize: deserializeBaseUser,
    deserializeProperty: deserializeBaseUserProp,
  ),
  embeddedSchemas: [],
);

@isarProtected
int serializeBaseUser(IsarWriter writer, BaseUser object) {
  return object.id;
}

@isarProtected
BaseUser deserializeBaseUser(IsarReader reader) {
  final int _id;
  _id = IsarCore.readId(reader);
  final object = BaseUser(
    id: _id,
  );
  return object;
}

@isarProtected
dynamic deserializeBaseUserProp(IsarReader reader, int property) {
  switch (property) {
    case 0:
      return IsarCore.readId(reader);
    default:
      throw ArgumentError('Unknown property: $property');
  }
}

extension BaseUserQueryFilter
    on QueryBuilder<BaseUser, BaseUser, QFilterCondition> {
  QueryBuilder<BaseUser, BaseUser, QAfterFilterCondition> idEqualTo(
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

  QueryBuilder<BaseUser, BaseUser, QAfterFilterCondition> idGreaterThan(
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

  QueryBuilder<BaseUser, BaseUser, QAfterFilterCondition>
      idGreaterThanOrEqualTo(
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

  QueryBuilder<BaseUser, BaseUser, QAfterFilterCondition> idLessThan(
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

  QueryBuilder<BaseUser, BaseUser, QAfterFilterCondition> idLessThanOrEqualTo(
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

  QueryBuilder<BaseUser, BaseUser, QAfterFilterCondition> idBetween(
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

extension BaseUserQueryObject
    on QueryBuilder<BaseUser, BaseUser, QFilterCondition> {}

extension BaseUserQuerySortBy on QueryBuilder<BaseUser, BaseUser, QSortBy> {
  QueryBuilder<BaseUser, BaseUser, QAfterSortBy> sortById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0);
    });
  }

  QueryBuilder<BaseUser, BaseUser, QAfterSortBy> sortByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0, sort: Sort.desc);
    });
  }
}

extension BaseUserQuerySortThenBy
    on QueryBuilder<BaseUser, BaseUser, QSortThenBy> {
  QueryBuilder<BaseUser, BaseUser, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0);
    });
  }

  QueryBuilder<BaseUser, BaseUser, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(0, sort: Sort.desc);
    });
  }
}

extension BaseUserQueryWhereDistinct
    on QueryBuilder<BaseUser, BaseUser, QDistinct> {}

extension BaseUserQueryProperty1
    on QueryBuilder<BaseUser, BaseUser, QProperty> {
  QueryBuilder<BaseUser, int, QAfterProperty> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addProperty(0);
    });
  }
}

extension BaseUserQueryProperty2<R>
    on QueryBuilder<BaseUser, R, QAfterProperty> {
  QueryBuilder<BaseUser, (R, int), QAfterProperty> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addProperty(0);
    });
  }
}

extension BaseUserQueryProperty3<R1, R2>
    on QueryBuilder<BaseUser, (R1, R2), QAfterProperty> {
  QueryBuilder<BaseUser, (R1, R2, int), QOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addProperty(0);
    });
  }
}
