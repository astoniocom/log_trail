// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'test_database.dart';

// ignore_for_file: type=lint
class $LogEntriesTable extends LogEntries
    with TableInfo<$LogEntriesTable, LogEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LogEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<int> time = GeneratedColumn<int>(
    'time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _levelMeta = const VerificationMeta('level');
  @override
  late final GeneratedColumn<String> level = GeneratedColumn<String>(
    'level',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entryMeta = const VerificationMeta('entry');
  @override
  late final GeneratedColumn<String> entry = GeneratedColumn<String>(
    'entry',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attributesMeta = const VerificationMeta(
    'attributes',
  );
  @override
  late final GeneratedColumn<String> attributes = GeneratedColumn<String>(
    'attributes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    time,
    level,
    entry,
    tags,
    attributes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'log_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<LogEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('time')) {
      context.handle(
        _timeMeta,
        time.isAcceptableOrUnknown(data['time']!, _timeMeta),
      );
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    if (data.containsKey('level')) {
      context.handle(
        _levelMeta,
        level.isAcceptableOrUnknown(data['level']!, _levelMeta),
      );
    } else if (isInserting) {
      context.missing(_levelMeta);
    }
    if (data.containsKey('entry')) {
      context.handle(
        _entryMeta,
        entry.isAcceptableOrUnknown(data['entry']!, _entryMeta),
      );
    } else if (isInserting) {
      context.missing(_entryMeta);
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    } else if (isInserting) {
      context.missing(_tagsMeta);
    }
    if (data.containsKey('attributes')) {
      context.handle(
        _attributesMeta,
        attributes.isAcceptableOrUnknown(data['attributes']!, _attributesMeta),
      );
    } else if (isInserting) {
      context.missing(_attributesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LogEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LogEntryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      time: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}time'],
      )!,
      level: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}level'],
      )!,
      entry: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entry'],
      )!,
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      )!,
      attributes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attributes'],
      )!,
    );
  }

  @override
  $LogEntriesTable createAlias(String alias) {
    return $LogEntriesTable(attachedDatabase, alias);
  }
}

class LogEntryRow extends DataClass implements Insertable<LogEntryRow> {
  /// Store id and the table's primary key: grows in write order and is never
  /// reused (`INTEGER PRIMARY KEY AUTOINCREMENT`).
  final int id;

  /// Entry time, microseconds since the epoch in UTC.
  final int time;

  /// `LogLevel.name`.
  final String level;

  /// The whole entry as JSON (`logEntryJson`).
  final String entry;

  /// Tags, each wrapped in U+001F: `\u001Fnet\u001Fauth\u001F`.
  final String tags;

  /// Attributes as `\u001Fname=canonical JSON\u001F…`, map keys sorted so that
  /// equal values give equal text.
  final String attributes;
  const LogEntryRow({
    required this.id,
    required this.time,
    required this.level,
    required this.entry,
    required this.tags,
    required this.attributes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['time'] = Variable<int>(time);
    map['level'] = Variable<String>(level);
    map['entry'] = Variable<String>(entry);
    map['tags'] = Variable<String>(tags);
    map['attributes'] = Variable<String>(attributes);
    return map;
  }

  LogEntriesCompanion toCompanion(bool nullToAbsent) {
    return LogEntriesCompanion(
      id: Value(id),
      time: Value(time),
      level: Value(level),
      entry: Value(entry),
      tags: Value(tags),
      attributes: Value(attributes),
    );
  }

  factory LogEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LogEntryRow(
      id: serializer.fromJson<int>(json['id']),
      time: serializer.fromJson<int>(json['time']),
      level: serializer.fromJson<String>(json['level']),
      entry: serializer.fromJson<String>(json['entry']),
      tags: serializer.fromJson<String>(json['tags']),
      attributes: serializer.fromJson<String>(json['attributes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'time': serializer.toJson<int>(time),
      'level': serializer.toJson<String>(level),
      'entry': serializer.toJson<String>(entry),
      'tags': serializer.toJson<String>(tags),
      'attributes': serializer.toJson<String>(attributes),
    };
  }

  LogEntryRow copyWith({
    int? id,
    int? time,
    String? level,
    String? entry,
    String? tags,
    String? attributes,
  }) => LogEntryRow(
    id: id ?? this.id,
    time: time ?? this.time,
    level: level ?? this.level,
    entry: entry ?? this.entry,
    tags: tags ?? this.tags,
    attributes: attributes ?? this.attributes,
  );
  LogEntryRow copyWithCompanion(LogEntriesCompanion data) {
    return LogEntryRow(
      id: data.id.present ? data.id.value : this.id,
      time: data.time.present ? data.time.value : this.time,
      level: data.level.present ? data.level.value : this.level,
      entry: data.entry.present ? data.entry.value : this.entry,
      tags: data.tags.present ? data.tags.value : this.tags,
      attributes: data.attributes.present
          ? data.attributes.value
          : this.attributes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LogEntryRow(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('entry: $entry, ')
          ..write('tags: $tags, ')
          ..write('attributes: $attributes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, time, level, entry, tags, attributes);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LogEntryRow &&
          other.id == this.id &&
          other.time == this.time &&
          other.level == this.level &&
          other.entry == this.entry &&
          other.tags == this.tags &&
          other.attributes == this.attributes);
}

class LogEntriesCompanion extends UpdateCompanion<LogEntryRow> {
  final Value<int> id;
  final Value<int> time;
  final Value<String> level;
  final Value<String> entry;
  final Value<String> tags;
  final Value<String> attributes;
  const LogEntriesCompanion({
    this.id = const Value.absent(),
    this.time = const Value.absent(),
    this.level = const Value.absent(),
    this.entry = const Value.absent(),
    this.tags = const Value.absent(),
    this.attributes = const Value.absent(),
  });
  LogEntriesCompanion.insert({
    this.id = const Value.absent(),
    required int time,
    required String level,
    required String entry,
    required String tags,
    required String attributes,
  }) : time = Value(time),
       level = Value(level),
       entry = Value(entry),
       tags = Value(tags),
       attributes = Value(attributes);
  static Insertable<LogEntryRow> custom({
    Expression<int>? id,
    Expression<int>? time,
    Expression<String>? level,
    Expression<String>? entry,
    Expression<String>? tags,
    Expression<String>? attributes,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (time != null) 'time': time,
      if (level != null) 'level': level,
      if (entry != null) 'entry': entry,
      if (tags != null) 'tags': tags,
      if (attributes != null) 'attributes': attributes,
    });
  }

  LogEntriesCompanion copyWith({
    Value<int>? id,
    Value<int>? time,
    Value<String>? level,
    Value<String>? entry,
    Value<String>? tags,
    Value<String>? attributes,
  }) {
    return LogEntriesCompanion(
      id: id ?? this.id,
      time: time ?? this.time,
      level: level ?? this.level,
      entry: entry ?? this.entry,
      tags: tags ?? this.tags,
      attributes: attributes ?? this.attributes,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (time.present) {
      map['time'] = Variable<int>(time.value);
    }
    if (level.present) {
      map['level'] = Variable<String>(level.value);
    }
    if (entry.present) {
      map['entry'] = Variable<String>(entry.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (attributes.present) {
      map['attributes'] = Variable<String>(attributes.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LogEntriesCompanion(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('entry: $entry, ')
          ..write('tags: $tags, ')
          ..write('attributes: $attributes')
          ..write(')'))
        .toString();
  }
}

class $TenantLogsTable extends TenantLogs
    with TableInfo<$TenantLogsTable, TenantLog> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TenantLogsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<int> time = GeneratedColumn<int>(
    'time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _levelMeta = const VerificationMeta('level');
  @override
  late final GeneratedColumn<String> level = GeneratedColumn<String>(
    'level',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entryMeta = const VerificationMeta('entry');
  @override
  late final GeneratedColumn<String> entry = GeneratedColumn<String>(
    'entry',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attributesMeta = const VerificationMeta(
    'attributes',
  );
  @override
  late final GeneratedColumn<String> attributes = GeneratedColumn<String>(
    'attributes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tenantMeta = const VerificationMeta('tenant');
  @override
  late final GeneratedColumn<String> tenant = GeneratedColumn<String>(
    'tenant',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    time,
    level,
    entry,
    tags,
    attributes,
    tenant,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tenant_logs';
  @override
  VerificationContext validateIntegrity(
    Insertable<TenantLog> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('time')) {
      context.handle(
        _timeMeta,
        time.isAcceptableOrUnknown(data['time']!, _timeMeta),
      );
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    if (data.containsKey('level')) {
      context.handle(
        _levelMeta,
        level.isAcceptableOrUnknown(data['level']!, _levelMeta),
      );
    } else if (isInserting) {
      context.missing(_levelMeta);
    }
    if (data.containsKey('entry')) {
      context.handle(
        _entryMeta,
        entry.isAcceptableOrUnknown(data['entry']!, _entryMeta),
      );
    } else if (isInserting) {
      context.missing(_entryMeta);
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    } else if (isInserting) {
      context.missing(_tagsMeta);
    }
    if (data.containsKey('attributes')) {
      context.handle(
        _attributesMeta,
        attributes.isAcceptableOrUnknown(data['attributes']!, _attributesMeta),
      );
    } else if (isInserting) {
      context.missing(_attributesMeta);
    }
    if (data.containsKey('tenant')) {
      context.handle(
        _tenantMeta,
        tenant.isAcceptableOrUnknown(data['tenant']!, _tenantMeta),
      );
    } else if (isInserting) {
      context.missing(_tenantMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TenantLog map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TenantLog(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      time: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}time'],
      )!,
      level: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}level'],
      )!,
      entry: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entry'],
      )!,
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      )!,
      attributes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attributes'],
      )!,
      tenant: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tenant'],
      )!,
    );
  }

  @override
  $TenantLogsTable createAlias(String alias) {
    return $TenantLogsTable(attachedDatabase, alias);
  }
}

class TenantLog extends DataClass implements Insertable<TenantLog> {
  /// Store id and the table's primary key: grows in write order and is never
  /// reused (`INTEGER PRIMARY KEY AUTOINCREMENT`).
  final int id;

  /// Entry time, microseconds since the epoch in UTC.
  final int time;

  /// `LogLevel.name`.
  final String level;

  /// The whole entry as JSON (`logEntryJson`).
  final String entry;

  /// Tags, each wrapped in U+001F: `\u001Fnet\u001Fauth\u001F`.
  final String tags;

  /// Attributes as `\u001Fname=canonical JSON\u001F…`, map keys sorted so that
  /// equal values give equal text.
  final String attributes;
  final String tenant;
  const TenantLog({
    required this.id,
    required this.time,
    required this.level,
    required this.entry,
    required this.tags,
    required this.attributes,
    required this.tenant,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['time'] = Variable<int>(time);
    map['level'] = Variable<String>(level);
    map['entry'] = Variable<String>(entry);
    map['tags'] = Variable<String>(tags);
    map['attributes'] = Variable<String>(attributes);
    map['tenant'] = Variable<String>(tenant);
    return map;
  }

  TenantLogsCompanion toCompanion(bool nullToAbsent) {
    return TenantLogsCompanion(
      id: Value(id),
      time: Value(time),
      level: Value(level),
      entry: Value(entry),
      tags: Value(tags),
      attributes: Value(attributes),
      tenant: Value(tenant),
    );
  }

  factory TenantLog.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TenantLog(
      id: serializer.fromJson<int>(json['id']),
      time: serializer.fromJson<int>(json['time']),
      level: serializer.fromJson<String>(json['level']),
      entry: serializer.fromJson<String>(json['entry']),
      tags: serializer.fromJson<String>(json['tags']),
      attributes: serializer.fromJson<String>(json['attributes']),
      tenant: serializer.fromJson<String>(json['tenant']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'time': serializer.toJson<int>(time),
      'level': serializer.toJson<String>(level),
      'entry': serializer.toJson<String>(entry),
      'tags': serializer.toJson<String>(tags),
      'attributes': serializer.toJson<String>(attributes),
      'tenant': serializer.toJson<String>(tenant),
    };
  }

  TenantLog copyWith({
    int? id,
    int? time,
    String? level,
    String? entry,
    String? tags,
    String? attributes,
    String? tenant,
  }) => TenantLog(
    id: id ?? this.id,
    time: time ?? this.time,
    level: level ?? this.level,
    entry: entry ?? this.entry,
    tags: tags ?? this.tags,
    attributes: attributes ?? this.attributes,
    tenant: tenant ?? this.tenant,
  );
  TenantLog copyWithCompanion(TenantLogsCompanion data) {
    return TenantLog(
      id: data.id.present ? data.id.value : this.id,
      time: data.time.present ? data.time.value : this.time,
      level: data.level.present ? data.level.value : this.level,
      entry: data.entry.present ? data.entry.value : this.entry,
      tags: data.tags.present ? data.tags.value : this.tags,
      attributes: data.attributes.present
          ? data.attributes.value
          : this.attributes,
      tenant: data.tenant.present ? data.tenant.value : this.tenant,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TenantLog(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('entry: $entry, ')
          ..write('tags: $tags, ')
          ..write('attributes: $attributes, ')
          ..write('tenant: $tenant')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, time, level, entry, tags, attributes, tenant);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TenantLog &&
          other.id == this.id &&
          other.time == this.time &&
          other.level == this.level &&
          other.entry == this.entry &&
          other.tags == this.tags &&
          other.attributes == this.attributes &&
          other.tenant == this.tenant);
}

class TenantLogsCompanion extends UpdateCompanion<TenantLog> {
  final Value<int> id;
  final Value<int> time;
  final Value<String> level;
  final Value<String> entry;
  final Value<String> tags;
  final Value<String> attributes;
  final Value<String> tenant;
  const TenantLogsCompanion({
    this.id = const Value.absent(),
    this.time = const Value.absent(),
    this.level = const Value.absent(),
    this.entry = const Value.absent(),
    this.tags = const Value.absent(),
    this.attributes = const Value.absent(),
    this.tenant = const Value.absent(),
  });
  TenantLogsCompanion.insert({
    this.id = const Value.absent(),
    required int time,
    required String level,
    required String entry,
    required String tags,
    required String attributes,
    required String tenant,
  }) : time = Value(time),
       level = Value(level),
       entry = Value(entry),
       tags = Value(tags),
       attributes = Value(attributes),
       tenant = Value(tenant);
  static Insertable<TenantLog> custom({
    Expression<int>? id,
    Expression<int>? time,
    Expression<String>? level,
    Expression<String>? entry,
    Expression<String>? tags,
    Expression<String>? attributes,
    Expression<String>? tenant,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (time != null) 'time': time,
      if (level != null) 'level': level,
      if (entry != null) 'entry': entry,
      if (tags != null) 'tags': tags,
      if (attributes != null) 'attributes': attributes,
      if (tenant != null) 'tenant': tenant,
    });
  }

  TenantLogsCompanion copyWith({
    Value<int>? id,
    Value<int>? time,
    Value<String>? level,
    Value<String>? entry,
    Value<String>? tags,
    Value<String>? attributes,
    Value<String>? tenant,
  }) {
    return TenantLogsCompanion(
      id: id ?? this.id,
      time: time ?? this.time,
      level: level ?? this.level,
      entry: entry ?? this.entry,
      tags: tags ?? this.tags,
      attributes: attributes ?? this.attributes,
      tenant: tenant ?? this.tenant,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (time.present) {
      map['time'] = Variable<int>(time.value);
    }
    if (level.present) {
      map['level'] = Variable<String>(level.value);
    }
    if (entry.present) {
      map['entry'] = Variable<String>(entry.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (attributes.present) {
      map['attributes'] = Variable<String>(attributes.value);
    }
    if (tenant.present) {
      map['tenant'] = Variable<String>(tenant.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TenantLogsCompanion(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('entry: $entry, ')
          ..write('tags: $tags, ')
          ..write('attributes: $attributes, ')
          ..write('tenant: $tenant')
          ..write(')'))
        .toString();
  }
}

abstract class _$TestDatabase extends GeneratedDatabase {
  _$TestDatabase(QueryExecutor e) : super(e);
  $TestDatabaseManager get managers => $TestDatabaseManager(this);
  late final $LogEntriesTable logEntries = $LogEntriesTable(this);
  late final $TenantLogsTable tenantLogs = $TenantLogsTable(this);
  late final Index logEntriesByTime = Index(
    'log_entries_by_time',
    'CREATE INDEX log_entries_by_time ON log_entries (time, id)',
  );
  late final Index tenantLogsByTime = Index(
    'tenant_logs_by_time',
    'CREATE INDEX tenant_logs_by_time ON tenant_logs (time, id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    logEntries,
    tenantLogs,
    logEntriesByTime,
    tenantLogsByTime,
  ];
}

typedef $$LogEntriesTableCreateCompanionBuilder = LogEntriesCompanion Function({
  Value<int> id,
  required int time,
  required String level,
  required String entry,
  required String tags,
  required String attributes,
});
typedef $$LogEntriesTableUpdateCompanionBuilder = LogEntriesCompanion Function({
  Value<int> id,
  Value<int> time,
  Value<String> level,
  Value<String> entry,
  Value<String> tags,
  Value<String> attributes,
});

class $$LogEntriesTableFilterComposer
    extends Composer<_$TestDatabase, $LogEntriesTable> {
  $$LogEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entry => $composableBuilder(
    column: $table.entry,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attributes => $composableBuilder(
    column: $table.attributes,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LogEntriesTableOrderingComposer
    extends Composer<_$TestDatabase, $LogEntriesTable> {
  $$LogEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entry => $composableBuilder(
    column: $table.entry,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attributes => $composableBuilder(
    column: $table.attributes,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LogEntriesTableAnnotationComposer
    extends Composer<_$TestDatabase, $LogEntriesTable> {
  $$LogEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<String> get level =>
      $composableBuilder(column: $table.level, builder: (column) => column);

  GeneratedColumn<String> get entry =>
      $composableBuilder(column: $table.entry, builder: (column) => column);

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get attributes => $composableBuilder(
    column: $table.attributes,
    builder: (column) => column,
  );
}

class $$LogEntriesTableTableManager
    extends
        RootTableManager<
          _$TestDatabase,
          $LogEntriesTable,
          LogEntryRow,
          $$LogEntriesTableFilterComposer,
          $$LogEntriesTableOrderingComposer,
          $$LogEntriesTableAnnotationComposer,
          $$LogEntriesTableCreateCompanionBuilder,
          $$LogEntriesTableUpdateCompanionBuilder,
          (
            LogEntryRow,
            BaseReferences<_$TestDatabase, $LogEntriesTable, LogEntryRow>,
          ),
          LogEntryRow,
          PrefetchHooks Function()
        > {
  $$LogEntriesTableTableManager(_$TestDatabase db, $LogEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LogEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LogEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LogEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> time = const Value.absent(),
                Value<String> level = const Value.absent(),
                Value<String> entry = const Value.absent(),
                Value<String> tags = const Value.absent(),
                Value<String> attributes = const Value.absent(),
              }) => LogEntriesCompanion(
                id: id,
                time: time,
                level: level,
                entry: entry,
                tags: tags,
                attributes: attributes,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int time,
                required String level,
                required String entry,
                required String tags,
                required String attributes,
              }) => LogEntriesCompanion.insert(
                id: id,
                time: time,
                level: level,
                entry: entry,
                tags: tags,
                attributes: attributes,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LogEntriesTable, LogEntryRow>(table),
                  BaseReferences<_$TestDatabase, $LogEntriesTable, LogEntryRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LogEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$TestDatabase,
      $LogEntriesTable,
      LogEntryRow,
      $$LogEntriesTableFilterComposer,
      $$LogEntriesTableOrderingComposer,
      $$LogEntriesTableAnnotationComposer,
      $$LogEntriesTableCreateCompanionBuilder,
      $$LogEntriesTableUpdateCompanionBuilder,
      (
        LogEntryRow,
        BaseReferences<_$TestDatabase, $LogEntriesTable, LogEntryRow>,
      ),
      LogEntryRow,
      PrefetchHooks Function()
    >;
typedef $$TenantLogsTableCreateCompanionBuilder = TenantLogsCompanion Function({
  Value<int> id,
  required int time,
  required String level,
  required String entry,
  required String tags,
  required String attributes,
  required String tenant,
});
typedef $$TenantLogsTableUpdateCompanionBuilder = TenantLogsCompanion Function({
  Value<int> id,
  Value<int> time,
  Value<String> level,
  Value<String> entry,
  Value<String> tags,
  Value<String> attributes,
  Value<String> tenant,
});

class $$TenantLogsTableFilterComposer
    extends Composer<_$TestDatabase, $TenantLogsTable> {
  $$TenantLogsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entry => $composableBuilder(
    column: $table.entry,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attributes => $composableBuilder(
    column: $table.attributes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tenant => $composableBuilder(
    column: $table.tenant,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TenantLogsTableOrderingComposer
    extends Composer<_$TestDatabase, $TenantLogsTable> {
  $$TenantLogsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entry => $composableBuilder(
    column: $table.entry,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attributes => $composableBuilder(
    column: $table.attributes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tenant => $composableBuilder(
    column: $table.tenant,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TenantLogsTableAnnotationComposer
    extends Composer<_$TestDatabase, $TenantLogsTable> {
  $$TenantLogsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<String> get level =>
      $composableBuilder(column: $table.level, builder: (column) => column);

  GeneratedColumn<String> get entry =>
      $composableBuilder(column: $table.entry, builder: (column) => column);

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get attributes => $composableBuilder(
    column: $table.attributes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tenant =>
      $composableBuilder(column: $table.tenant, builder: (column) => column);
}

class $$TenantLogsTableTableManager
    extends
        RootTableManager<
          _$TestDatabase,
          $TenantLogsTable,
          TenantLog,
          $$TenantLogsTableFilterComposer,
          $$TenantLogsTableOrderingComposer,
          $$TenantLogsTableAnnotationComposer,
          $$TenantLogsTableCreateCompanionBuilder,
          $$TenantLogsTableUpdateCompanionBuilder,
          (
            TenantLog,
            BaseReferences<_$TestDatabase, $TenantLogsTable, TenantLog>,
          ),
          TenantLog,
          PrefetchHooks Function()
        > {
  $$TenantLogsTableTableManager(_$TestDatabase db, $TenantLogsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TenantLogsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TenantLogsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TenantLogsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> time = const Value.absent(),
                Value<String> level = const Value.absent(),
                Value<String> entry = const Value.absent(),
                Value<String> tags = const Value.absent(),
                Value<String> attributes = const Value.absent(),
                Value<String> tenant = const Value.absent(),
              }) => TenantLogsCompanion(
                id: id,
                time: time,
                level: level,
                entry: entry,
                tags: tags,
                attributes: attributes,
                tenant: tenant,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int time,
                required String level,
                required String entry,
                required String tags,
                required String attributes,
                required String tenant,
              }) => TenantLogsCompanion.insert(
                id: id,
                time: time,
                level: level,
                entry: entry,
                tags: tags,
                attributes: attributes,
                tenant: tenant,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TenantLogsTable, TenantLog>(table),
                  BaseReferences<_$TestDatabase, $TenantLogsTable, TenantLog>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TenantLogsTableProcessedTableManager =
    ProcessedTableManager<
      _$TestDatabase,
      $TenantLogsTable,
      TenantLog,
      $$TenantLogsTableFilterComposer,
      $$TenantLogsTableOrderingComposer,
      $$TenantLogsTableAnnotationComposer,
      $$TenantLogsTableCreateCompanionBuilder,
      $$TenantLogsTableUpdateCompanionBuilder,
      (TenantLog, BaseReferences<_$TestDatabase, $TenantLogsTable, TenantLog>),
      TenantLog,
      PrefetchHooks Function()
    >;

class $TestDatabaseManager {
  final _$TestDatabase _db;
  $TestDatabaseManager(this._db);
  $$LogEntriesTableTableManager get logEntries =>
      $$LogEntriesTableTableManager(_db, _db.logEntries);
  $$TenantLogsTableTableManager get tenantLogs =>
      $$TenantLogsTableTableManager(_db, _db.tenantLogs);
}
