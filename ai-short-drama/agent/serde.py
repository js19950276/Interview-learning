"""通用 dataclass <-> dict 序列化工具.

支持:
- 嵌套 dataclass
- Enum (通过 .value 双向转换)
- Path <-> str
- Optional / Union[X, None]
- list[X], dict[K, V] 泛型 (PEP 585)
- field metadata={"transient": True} 字段会被跳过 (用于锁等不可序列化对象)
"""
from __future__ import annotations

import dataclasses
from enum import Enum
from pathlib import Path
from typing import Any, Type, Union, get_args, get_origin, get_type_hints

try:
    from types import UnionType  # Python 3.10+
    _UNION_ORIGINS = {Union, UnionType}
except ImportError:
    _UNION_ORIGINS = {Union}


def to_serializable(obj: Any) -> Any:
    if dataclasses.is_dataclass(obj) and not isinstance(obj, type):
        return {
            f.name: to_serializable(getattr(obj, f.name))
            for f in dataclasses.fields(obj)
            if not f.metadata.get("transient")
        }
    if isinstance(obj, Enum):
        return obj.value
    if isinstance(obj, Path):
        return str(obj)
    if isinstance(obj, (list, tuple)):
        return [to_serializable(x) for x in obj]
    if isinstance(obj, dict):
        return {str(k): to_serializable(v) for k, v in obj.items()}
    return obj


def from_dict(cls: Type, data: Any) -> Any:
    if data is None:
        return None
    if not dataclasses.is_dataclass(cls):
        return _coerce(cls, data)
    if not isinstance(data, dict):
        raise TypeError(f"Expected dict for {cls.__name__}, got {type(data).__name__}")

    hints = get_type_hints(cls)
    kwargs = {}
    for f in dataclasses.fields(cls):
        if f.metadata.get("transient"):
            continue
        if f.name not in data:
            continue
        field_type = hints.get(f.name, f.type)
        kwargs[f.name] = _coerce(field_type, data[f.name])
    return cls(**kwargs)


def _coerce(typ: Any, value: Any) -> Any:
    if value is None:
        return None

    origin = get_origin(typ)
    args = get_args(typ)

    if origin in _UNION_ORIGINS:
        non_none = [t for t in args if t is not type(None)]
        if len(non_none) == 1:
            return _coerce(non_none[0], value)
        for t in non_none:
            try:
                return _coerce(t, value)
            except (TypeError, ValueError):
                continue
        return value

    if origin in (list, tuple):
        elem_type = args[0] if args else Any
        return [_coerce(elem_type, v) for v in value]

    if origin is dict:
        if len(args) == 2:
            key_type, val_type = args
            return {key_type(k): _coerce(val_type, v) for k, v in value.items()}
        return dict(value)

    if isinstance(typ, type):
        if issubclass(typ, Enum):
            return typ(value)
        if typ is Path:
            return Path(value)
        if dataclasses.is_dataclass(typ):
            return from_dict(typ, value)

    return value
