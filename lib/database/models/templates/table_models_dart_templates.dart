import 'package:dart_style/dart_style.dart';
import 'package:query_builder/database/models/parsers/data_type_model.dart';
import 'package:query_builder/database/models/parsers/table_models.dart';
import 'package:query_builder/src/extensions.dart';

class SqlTableDartTemplate {
  final SqlTable table;

  final _formatter =
      DartFormatter(languageVersion: DartFormatter.latestLanguageVersion);

  SqlTableDartTemplate({required this.table});

  String dartClass(List<SqlTable> allTables) {
    final mapAllTables = allTables.fold<Map<String, SqlTable>>(
      {},
      (value, element) => value..set(element.name, element),
    );

    String sourceCode = """
import 'dart:convert';

import 'package:query_builder/database/models/sql_values.dart';

${allTables.map((e) => e.templates.singleClass(mapAllTables)).join('\n\n')}

""";
    try {
      sourceCode = _formatter.format(sourceCode);
    } catch (_) {}
    return sourceCode;
  }

  String singleClass(Map<String, SqlTable> mapAllTables) {
    return """

class $className{
  ${table.columns.map((e) => 'final ${_dartType(e.type, nullable: e.nullable)} ${e.name.snakeToCamel()};').join()}

  ${table.foreignKeys.map((e) => 'final List<${e.reference.className}>? ref${e.reference.className};').join()}

  final Map<String, Object?> additionalInfo;

  const $className({
    ${table.columns.map((e) => '${e.nullable ? "" : "required "}this.${e.name.snakeToCamel()},').join()}
    ${table.foreignKeys.map((e) => 'this.ref${e.reference.className},').join()}
    this.additionalInfo = const {},
  });

  SqlQuery insertShallowSql(SqlDatabase database) {
    final ctx = SqlContext(database: database, unsafe: false);
    final text =  \"""
INSERT INTO ${table.name}(${table.columns.map((e) => e.name).join(',')})
VALUES (${table.columns.map((e) => '\${${toSqlValue(e)}.toSql(ctx)}').join(',')});
\""";

    return SqlQuery(text, ctx.variables);
  }

  Future<SqlQueryResult> insertShallow(TableConnection conn) {
    final sqlQuery = insertShallowSql(conn.database);
    return conn.query(sqlQuery.query, sqlQuery.params);
  }

  static SqlQuery selectSql(${_joinParams(withDatabase: true)}) {
    final ctx = SqlContext(database: database, unsafe: unsafe);
    final query = \"""
SELECT ${table.columns.map((e) => e.name).join(',')}
${_joinSelects(mapAllTables)}
FROM ${table.name}
${table.foreignKeys.map(foreignKeyJoin).join('\n')}
\${where == null ? '' : 'WHERE \${where.toSql(ctx)}'}
GROUP BY ${table.primaryKey?.columns.map((e) => e.columnName).join(',')}
\${orderBy == null ? '' : 'ORDER BY \${orderBy.map((item) => item.toSql(ctx)).join(",")}'}
\${limit == null ? '' : 'LIMIT \${limit.rowCount} \${limit.offset == null ? "" : "OFFSET \${limit.offset}"}'}
;
\""";
    return SqlQuery(query, ctx.variables);
  }

  static Future<List<$className>> select(TableConnection conn,${_joinParams()}) async {
    final query = $className.selectSql(where:where, limit:limit, orderBy:orderBy, database: conn.database,${table.foreignKeys.map((e) => "with${e.reference.className}: with${e.reference.className},").join()});

    final result = await conn.query(query.query, query.params);
    int _refIndex = ${table.columns.length};

    return result.map((r) {
      return $className(
        ${table.columns.mapIndex((e, i) => parseColumn(e, getter: 'r[$i]')).join()}
        ${table.foreignKeys.map((e) => 'ref${e.reference.className}: with${e.reference.className} ? ${joinFromJsonList(e, "r[_refIndex++]")} : null,').join()}
      );
    }).toList();
  }

  factory $className.fromJson(dynamic json) {
    final Map map;
    if (json is $className) {
      return json;
    } else if (json is Map) {
      map = json;
    } else if (json is String) {
      map = jsonDecode(json) as Map;
    } else {
      throw Error();
    }

    return $className(
      ${table.columns.map(parseColumn).join()}
      ${table.foreignKeys.map((e) => "ref${e.reference.className}:${joinFromJsonList(e, 'map["ref${e.reference.className}"]')},").join()}
    );
  }

  static List<$className>? listFromJson(dynamic _json) {
    final Object? json = _json is String ? jsonDecode(_json) : _json;

    if (json is List || json is Set) {
      return (json as Iterable).map((Object? e) => $className.fromJson(e)).toList();
    } else if (json is Map) {
      final _jsonMap = json.cast<String, List>();
      ${table.columns.map((e) => 'final ${e.name.snakeToCamel()}=_jsonMap["${e.name.snakeToCamel()}"];').join()}
      ${table.foreignKeys.map((e) => "final ref${e.reference.className}=_jsonMap['ref${e.reference.className}'];").join()}
      return Iterable.generate(
        (${table.columns.map((e) => e.name.snakeToCamel()).followedBy(table.foreignKeys.map((e) => 'ref${e.reference.className}')).map((e) => '$e?.length').join(' ?? ')})!,
        (_ind) {
          return $className(
            ${table.columns.map((e) => parseColumn(e, getter: '(${e.name.snakeToCamel()}?[_ind])')).join()}
            ${table.foreignKeys.map((e) => "ref${e.reference.className}:${joinFromJsonList(e, 'ref${e.reference.className}?[_ind]')},").join()}
          );
        },
      ).toList();
    } else {
      return _json as List<$className>?;
    }
  }
}

class ${className}Cols {
  ${className}Cols(String tableAlias)
      : ${table.columns.map((e) => "${e.name.snakeToCamel()} = SqlValue.raw('\$tableAlias.${e.name}')").join(',')};

  ${table.columns.map((e) => "final SqlValue<${_mapTypeToSqlValue(e)}> ${e.name.snakeToCamel()};").join()}

  late final List<SqlValue> allColumns = [
    ${table.columns.map((e) => "${e.name.snakeToCamel()},").join()}
  ];
}    
""";
  }

  String foreignKeyJoin(SqlForeignKey e) =>
      '\${with${e.reference.className} ? "JOIN ${e.reference.referencedTable} ON '
      '${e.colItems().map(
            (c) => '${table.name}.${c.second}='
                '${e.reference.referencedTable}.${c.last.columnName}',
          ).join(" AND ")}" : ""}';

  String toSqlValue(SqlColumn col) {
    final name = '${col.name.snakeToCamel()}${col.nullable ? '?' : ''}';
    final getter = col.type.map(
      date: (date) {
        switch (date.type) {
          case SqlDateVariant.YEAR:
            return '$name.sqlYear';
          case SqlDateVariant.DATE:
            return '$name.sqlDate';
          case SqlDateVariant.TIMESTAMP:
          case SqlDateVariant.DATETIME:
            return '$name.sqlDateTime';
          case SqlDateVariant.TIME:
            return '$name.sqlTime';
        }
      },
      string: (string) => string.binary ? '$name.sql' : '$name.sql',
      enumeration: (enumeration) => '$name.sql',
      integer: (integer) => '$name.sql',
      decimal: (decimal) => '$name.sql',
      json: (json) => 'SqlValue.json($name)',
    );
    if (col.nullable) {
      return '($getter ?? SqlValue.null_)';
    }
    return getter;
  }

  String parseColumn(SqlColumn e, {String? getter}) {
    final type = _dartType(e.type, nullable: e.nullable);
    final key = e.name.snakeToCamel();
    final _getter = getter ?? "map['${e.name.snakeToCamel()}']";
    if (type == 'DateTime' || type == 'DateTime?') {
      return '$key: $_getter is $type ? $_getter as $type : $_getter is int '
          ' ? DateTime.fromMillisecondsSinceEpoch($_getter as int) : '
          ' DateTime.parse($_getter as String),';
    }
    return '$key:$_getter as $type,';
  }

  String joinFromJsonList(SqlForeignKey key, String varName) {
    final _tableClass = key.reference.className;
    return '$_tableClass.listFromJson($varName)';
  }

  String _mapTypeToSqlValue(SqlColumn col) {
    final type = col.type.map(
      date: (date) => date.type == SqlDateVariant.YEAR ? 'Date' : 'Date',
      string: (string) => string.binary ? 'Binary' : 'String',
      enumeration: (enumeration) => 'String',
      integer: (integer) => 'Num',
      decimal: (decimal) => 'Num',
      json: (json) => 'Json',
    );
    return 'Sql${type}Value';
  }

  String get className => table.name.snakeToCamel(firstUpperCase: true);

  String _joinParams({bool withDatabase = false}) {
    final _baseQuery =
        'SqlValue<SqlBoolValue>? where, List<SqlOrderItem>? orderBy, SqlLimit? limit, '
        '${withDatabase ? " required SqlDatabase database, bool unsafe = false," : ""}';
    if (table.foreignKeys.isEmpty) {
      return '{$_baseQuery}';
    }
    return '{$_baseQuery ${table.foreignKeys.map(
          (e) => "bool with${e.reference.className} = false,",
        ).join()}}';
  }

  String _joinSelects(Map<String, SqlTable> mapTables) {
    if (table.foreignKeys.isEmpty) {
      return '';
    }

    String? _mm(SqlTable? e) => e?.columns
        .map((c) => "'${c.name.snakeToCamel()}',${e.name}.${c.name}")
        .join(',');

    String _map(SqlForeignKey e) =>
        '\${with${e.reference.className} ? ",JSON_ARRAYAGG(JSON_OBJECT('
        '${_mm(mapTables.get(e.reference.referencedTable))}'
        ')) ref${e.reference.className}":""}';
    return table.foreignKeys.map(_map).join('\n');
  }

  String _dartType(SqlType type, {required bool nullable}) {
    return type.map(
          date: (date) => date.type == SqlDateVariant.YEAR ? 'int' : 'DateTime',
          string: (string) => string.binary ? 'List<int>' : 'String',
          enumeration: (enumeration) => 'String',
          integer: (integer) => 'int',
          decimal: (decimal) => 'double',
          json: (json) => 'Object',
        ) +
        (nullable ? '?' : '');
  }
}

extension _SqlReferenceExt on SqlReference {
  String get className => referencedTable.snakeToCamel(firstUpperCase: true);
}
