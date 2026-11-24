import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;

import 'episode_store.dart';
import 'reader_page.dart';
import 'reading_progress.dart';

// offline-comic-reader の catalog_page.dart を組み込むための土台ファイル。
// catalog_page.dart は main.dart の part だったため、このファイルの part に変更した。
// part 内で使う名前は、このファイルの import で供給する。

part 'catalog_page.dart';
