import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

part 'json_serialization.g.dart';

/// Translates a serializable object from string to object
typedef Object Deserializer(dynamic serialized);

@JsonSerializable()
class PrimitiveWrapper {
  Object wrapped;

  PrimitiveWrapper();

  Map<String, dynamic> toJson() => _$PrimitiveWrapperToJson(this);
  static PrimitiveWrapper fromJson(Map<String, dynamic> json) =>
      _$PrimitiveWrapperFromJson(json);
}

class JsonSerialization {
  Map<String, Deserializer> deserializers = {
    'asset:json_serialization/lib/json_serialization.dart#PrimitiveWrapper':
        (d) => PrimitiveWrapper.fromJson(d as Map<String, dynamic>)
  };

  JsonSerialization();

  void registerDeserializer(String key, Deserializer deserializer) {
    deserializers.putIfAbsent(key, () => deserializer);
  }

  String serialize(Object object) {
    Object transfer = object;
    if (object == null ||
        object is num ||
        object is String ||
        object is Map ||
        object is Iterable) {
      PrimitiveWrapper wrapper = new PrimitiveWrapper();
      wrapper.wrapped = object;
      transfer = wrapper;
    }
    return const JsonEncoder.withIndent(' ').convert(transfer);
  }

  Object deserialize(String data) {
    Map<String, dynamic> decoded = json.decode(data);

    String key = decoded['json_serializable.className'];
    Deserializer deserialize = deserializers[key];
    if (deserialize == null) {
      throw new Exception(
          "cannot deserialize $data, no deserializer registered");
    }

    Object deserialized = deserialize(decoded);
    if (deserialized is PrimitiveWrapper) return deserialized.wrapped;
    return deserialized;
  }
}
