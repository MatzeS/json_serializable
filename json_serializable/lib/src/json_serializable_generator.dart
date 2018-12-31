// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:source_gen/source_gen.dart';
import 'package:blackbird_common/member_identifier.dart';
import 'dart:async';
import 'decode_helper.dart';
import 'encoder_helper.dart';
import 'field_helpers.dart';
import 'helper_core.dart';
import 'type_helper.dart';
import 'type_helpers/convert_helper.dart';
import 'type_helpers/date_time_helper.dart';
import 'type_helpers/duration_helper.dart';
import 'type_helpers/enum_helper.dart';
import 'type_helpers/iterable_helper.dart';
import 'type_helpers/json_converter_helper.dart';
import 'type_helpers/json_helper.dart';
import 'type_helpers/map_helper.dart';
import 'type_helpers/uri_helper.dart';
import 'type_helpers/value_helper.dart';
import 'utils.dart';

class JsonSerializableGenerator
    extends GeneratorForAnnotation<JsonSerializable> {
  static const _coreHelpers = <TypeHelper>[
    IterableHelper(),
    MapHelper(),
    EnumHelper(),
    ValueHelper(),
  ];

  static const _defaultHelpers = <TypeHelper>[
    JsonHelper(),
    DateTimeHelper(),
    UriHelper(),
    DurationHelper(),
  ];

  final List<TypeHelper> _typeHelpers;

  Iterable<TypeHelper> get _allHelpers => const <TypeHelper>[
        ConvertHelper(),
        JsonConverterHelper()
      ].followedBy(_typeHelpers).followedBy(_coreHelpers);

  final JsonSerializable _config;

  JsonSerializable get config => _config.withDefaults();

  /// Creates an instance of [JsonSerializableGenerator].
  ///
  /// If [typeHelpers] is not provided, three built-in helpers are used:
  /// [JsonHelper], [DateTimeHelper], [DurationHelper] and [UriHelper].
  const JsonSerializableGenerator({
    JsonSerializable config,
    List<TypeHelper> typeHelpers,
  })  : _config = config ?? JsonSerializable.defaults,
        _typeHelpers = typeHelpers ?? _defaultHelpers;

  /// Creates an instance of [JsonSerializableGenerator].
  ///
  /// [typeHelpers] provides a set of [TypeHelper] that will be used along with
  /// the built-in helpers:
  /// [JsonHelper], [DateTimeHelper], [DurationHelper] and [UriHelper].
  factory JsonSerializableGenerator.withDefaultHelpers(
          Iterable<TypeHelper> typeHelpers,
          {JsonSerializable config}) =>
      JsonSerializableGenerator(
          config: config,
          typeHelpers:
              List.unmodifiable(typeHelpers.followedBy(_defaultHelpers)));

  @override
  FutureOr<String> generate(LibraryReader library, BuildStep buildStep) async {
    var values = Set<String>();

    for (var annotatedElement in library.annotatedWith(typeChecker)) {
      var generatedValue = generateForAnnotatedElement(annotatedElement.element,
          annotatedElement.annotation, buildStep, false);
      values.add(generatedValue);
    }

    var devices = library.allElements
        .where((e) =>
            TypeChecker.fromUrl("asset:blackbird/lib/src/device.dart#Device")
                .isAssignableFrom(e) &&
            !TypeChecker.fromUrl("asset:blackbird/lib/src/device.dart#Device")
                .isExactly(e) &&
            TypeChecker.fromUrl("asset:blackbird/lib/src/device.dart#Ignore")
                .annotationsOf(e)
                .isEmpty)
        .where((e) {
          return !deviceClassIsAbstract(e as ClassElement);
        })
        .map((e) => generateForAnnotatedElement(e, null, buildStep, true))
        .toList();

    return values.join('\n\n') + devices.join('\n\n');
  }

  @override
  String generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep,
      [bool deviceConstruction]) {
    if (element is! ClassElement) {
      final name = element.name;
      throw InvalidGenerationSourceError('Generator cannot target `$name`.',
          todo: 'Remove the JsonSerializable annotation from `$name`.',
          element: element);
    }

    final classElement = element as ClassElement;
    final helper =
        _GeneratorHelper(this, classElement, annotation, deviceConstruction);
    return helper._generate().join('\n');
  }
}

class _GeneratorHelper extends HelperCore with EncodeHelper, DecodeHelper {
  final JsonSerializableGenerator _generator;
  final _addedMembers = Set<String>();

  _GeneratorHelper(this._generator, ClassElement element,
      ConstantReader annotation, bool deviceConstruction)
      : super(element, mergeConfig(_generator.config, annotation),
            deviceConstruction);

  @override
  void addMember(String memberContent) {
    _addedMembers.add(memberContent);
  }

  @override
  Iterable<TypeHelper> get allTypeHelpers => _generator._allHelpers;

  Iterable<String> _generate() sync* {
    assert(_addedMembers.isEmpty);

    print(element);

    var sortedFields = createSortedFieldSet(element);

    if (TypeChecker.fromUrl("asset:blackbird/lib/src/device.dart#Device")
        .isAssignableFrom(element)) {
      sortedFields = sortedFields
          .where((f) => f.isPublic && !f.name.contains('blackbird'))
          .toList();
      sortedFields = sortedFields
          .where((f) =>
              isProperty(f.getter ?? f.setter) &&
              (f.getter ?? f.setter).isSynthetic)
          .toList();
    }

    // Used to keep track of why a field is ignored. Useful for providing
    // helpful errors when generating constructor calls that try to use one of
    // these fields.
    final unavailableReasons = <String, String>{};

    final accessibleFields = sortedFields.fold<Map<String, FieldElement>>(
        <String, FieldElement>{}, (map, field) {
      if (!field.isPublic) {
        unavailableReasons[field.name] = 'It is assigned to a private field.';
      } else if (field.getter == null) {
        assert(field.setter != null);
        unavailableReasons[field.name] =
            'Setter-only properties are not supported.';
        log.warning('Setters are ignored: ${element.name}.${field.name}');
      } else if (jsonKeyFor(field).ignore) {
        unavailableReasons[field.name] = 'It is assigned to an ignored field.';
      } else {
        assert(!map.containsKey(field.name));
        map[field.name] = field;
      }

      return map;
    });

    var accessibleFieldSet = accessibleFields.values.toSet();
    if (config.createFactory) {
      final createResult = createFactory(accessibleFields, unavailableReasons);
      yield createResult.output;

      accessibleFieldSet = accessibleFields.entries
          .where((e) => createResult.usedFields.contains(e.key))
          .map((e) => e.value)
          .toSet();
    }

    // Check for duplicate JSON keys due to colliding annotations.
    // We do this now, since we have a final field list after any pruning done
    // by `_writeCtor`.
    accessibleFieldSet.fold(Set<String>(), (Set<String> set, fe) {
      final jsonKey = nameAccess(fe);
      if (!set.add(jsonKey)) {
        throw InvalidGenerationSourceError(
            'More than one field has the JSON key `$jsonKey`.',
            todo: 'Check the `JsonKey` annotations on fields.',
            element: fe);
      }
      return set;
    });

    if (config.createToJson) {
      yield* createToJson(accessibleFieldSet);
    }

    yield* _addedMembers;
  }
}
