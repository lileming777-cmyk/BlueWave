"""BlueWave for Windows: Qt UI over a local FFmpeg/PortAudio playback pipeline."""
import argparse
import os
from pathlib import Path
import random
import sys
import tempfile
import threading
import time
import uuid
import wave

from PySide6.QtCore import Qt, QObject, Signal, Slot, QRunnable, QThreadPool, QTimer, QUrl
from PySide6.QtGui import QDesktopServices, QKeySequence, QPixmap, QShortcut, QImageReader
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout, QHBoxLayout, QInputDialog, QLabel, QListWidget, QListWidgetItem, QMainWindow, QMenu, QMessageBox, QPushButton, QSlider, QSplitter, QTabWidget, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget, QLineEdit, QSpinBox)

from audio import AudioSession
from core import Cancelled, Library, cover_path, discover_audio, output_rate, parse_lrc, probe, read_lyrics, refresh_unknown_track, existing_cover_path
from online_cover import CoverResult, OnlineCover, cached_cover, normalized


class Bridge(QObject):
    result = Signal(str, object, str)
    progress = Signal(str, str)
    audio_done = Signal(str, str)


class Work(QRunnable):
    def __init__(self, identity, function, cancel, bridge):
        super().__init__()
        self.identity, self.function, self.cancel, self.bridge = identity, function, cancel, bridge

    def run(self):
        result, error = None, ''
        try:
            if self.cancel.is_set():
                raise Cancelled()
            result = self.function(self.cancel, lambda text: self.bridge.progress.emit(self.identity, text))
        except Cancelled:
            error = '已取消'
        except Exception as exc:
            error = str(exc)
        self.bridge.result.emit(self.identity, result, error)


def clock(seconds):
    return f'{max(0, int(seconds)) // 60}:{max(0, int(seconds)) % 60:02d}'


class Settings(QDialog):
    def __init__(self, settings, parent):
        super().__init__(parent)
        self.setWindowTitle('播放设置')
        self.resize(440, 330)
        form = QFormLayout(self)
        self.normal = QCheckBox('开启单遍动态响度调整（−18 LUFS）')
        self.normal.setChecked(settings['normalize'])
        form.addRow('音量统一', self.normal)
        self.fade = QSpinBox()
        self.fade.setRange(0, 8)
        self.fade.setSuffix(' 秒（0 为关闭）')
        self.fade.setValue(settings['crossfade'])
        form.addRow('歌曲平滑过渡', self.fade)
        self.rate = QComboBox()
        for label, value in [('跟随音源', 0)] + [(f'{rate / 1000:g} kHz', rate) for rate in (44100, 48000, 88200, 96000, 176400, 192000)]:
            self.rate.addItem(label, value)
        self.rate.setCurrentIndex(max(0, self.rate.findData(settings['rate'])))
        form.addRow('软件输出采样率', self.rate)
        self.precision = QComboBox()
        for value in (16, 24, 32):
            self.precision.addItem(f'{value} bit' + (' 浮点' if value == 32 else ' 软件量化'), value)
        self.precision.setCurrentIndex(max(0, self.precision.findData(settings['precision'])))
        form.addRow('处理精度', self.precision)
        self.online_covers = QCheckBox('缺少本地封面时自动下载（Deezer / MusicBrainz）')
        self.online_covers.setChecked(settings['online_covers'])
        form.addRow('在线封面', self.online_covers)
        privacy = QLabel('仅查询当前播放歌曲的曲名、歌手和专辑名；不会上传音频或文件路径。歌手和歌名无法精确对应时显示歌名。')
        privacy.setWordWrap(True)
        form.addRow(privacy)
        note = QLabel('设置在下次播放或跳转时生效。DSD 转换为 PCM；最终输出格式由 Windows 和设备决定。平滑过渡使用两个共享输出流，单曲循环时不启用。')
        note.setWordWrap(True)
        form.addRow(note)
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        form.addRow(buttons)

    def values(self):
        return {'normalize': self.normal.isChecked(), 'crossfade': self.fade.value(), 'rate': self.rate.currentData(), 'precision': self.precision.currentData(), 'online_covers': self.online_covers.isChecked()}


class Window(QMainWindow):
    def __init__(self, library=None):
        super().__init__()
        self.library = library if library is not None else Library()
        self.setWindowTitle('BlueWave 蓝调音乐')
        self.resize(1180, 780)
        self.setMinimumSize(900, 620)
        self.setAcceptDrops(True)
        self.bridge = Bridge(self)
        self.bridge.result.connect(self.job_result)
        self.bridge.progress.connect(self.job_progress)
        self.bridge.audio_done.connect(self.audio_finished)
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(3)
        self.jobs = {}
        self.import_job = None
        self.cover_job = None
        self.online_cover = OnlineCover()
        self.album_artworks = {}
        self.current = None
        self.session = None
        self.fading = None
        self.fade_started = 0
        self.fade_length = 0
        self.paused = False
        self.queue = []
        self.queue_index = -1
        self.lyric_text = ''
        self.lyric_lines = []
        self.lyric_identity = None
        self.build_ui()
        self.refresh_navigation()
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(150)
        self.shortcuts = []
        for key, action in [('Space', self.toggle), ('Ctrl+O', lambda: self.pick_import(False)), ('Ctrl+L', self.favorite_current), ('Ctrl+Right', self.next), ('Ctrl+Left', self.previous)]:
            shortcut = QShortcut(QKeySequence(key), self)
            shortcut.activated.connect(action)
            self.shortcuts.append(shortcut)

    def button(self, text, callback, parent_layout):
        button = QPushButton(text)
        button.clicked.connect(callback)
        parent_layout.addWidget(button)
        return button

    def build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(18, 14, 18, 12)
        toolbar = QHBoxLayout()
        brand = QLabel('BlueWave  蓝调音乐')
        brand.setObjectName('brand')
        toolbar.addWidget(brand)
        toolbar.addStretch()
        self.search = QLineEdit()
        self.search.setPlaceholderText('搜索歌曲、艺人或专辑')
        self.search.setClearButtonEnabled(True)
        self.search.setMaximumWidth(330)
        self.search.textChanged.connect(self.refresh_tracks)
        toolbar.addWidget(self.search)
        self.button('导入音乐', lambda: self.pick_import(False), toolbar)
        self.button('导入文件夹', lambda: self.pick_import(True), toolbar)
        self.button('设置', self.settings, toolbar)
        more = self.button('•••', self.show_more, toolbar)
        more.setMaximumWidth(45)
        layout.addLayout(toolbar)
        body = QSplitter()
        layout.addWidget(body, 1)
        left = QWidget()
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 12, 10, 0)
        self.nav = QListWidget()
        self.nav.currentItemChanged.connect(self.nav_changed)
        self.nav.setContextMenuPolicy(Qt.CustomContextMenu)
        self.nav.customContextMenuRequested.connect(self.nav_menu)
        left_layout.addWidget(self.nav)
        self.button('＋ 新建播放列表', self.create_playlist, left_layout)
        body.addWidget(left)
        middle = QWidget()
        mid_layout = QVBoxLayout(middle)
        mid_layout.setContentsMargins(12, 10, 12, 0)
        title_row = QHBoxLayout()
        self.heading = QLabel('歌曲')
        self.heading.setObjectName('heading')
        title_row.addWidget(self.heading)
        title_row.addStretch()
        self.group = QComboBox()
        self.group.setMinimumWidth(200)
        self.group.currentIndexChanged.connect(self.refresh_tracks)
        title_row.addWidget(self.group)
        mid_layout.addLayout(title_row)
        self.table = QTreeWidget()
        self.table.setHeaderLabels(['歌曲', '艺人', '专辑', '时长', '格式'])
        self.table.setRootIsDecorated(False)
        self.table.setAlternatingRowColors(True)
        self.table.setUniformRowHeights(True)
        self.table.setSelectionMode(QAbstractItemView.ExtendedSelection)
        self.table.setContextMenuPolicy(Qt.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self.track_menu)
        self.table.itemDoubleClicked.connect(self.play_item)
        self.table.setDragDropMode(QAbstractItemView.InternalMove)
        self.table.setDefaultDropAction(Qt.MoveAction)
        self.table.model().rowsMoved.connect(lambda *args: QTimer.singleShot(0, self.persist_order))
        self.table.setColumnWidth(0, 260)
        self.table.setColumnWidth(1, 140)
        self.table.setColumnWidth(2, 160)
        mid_layout.addWidget(self.table, 1)
        self.empty = QLabel('将音乐文件或文件夹拖到这里，开始聆听。')
        self.empty.setAlignment(Qt.AlignCenter)
        mid_layout.addWidget(self.empty)
        body.addWidget(middle)
        self.details = QTabWidget()
        self.details.setMinimumWidth(240)
        lyric_widget = QWidget()
        lyric_layout = QVBoxLayout(lyric_widget)
        self.lyric_origin = QLabel('歌词')
        self.lyric_origin.setWordWrap(True)
        lyric_layout.addWidget(self.lyric_origin)
        self.lyric_list = QListWidget()
        self.lyric_list.itemDoubleClicked.connect(self.seek_lyric)
        lyric_layout.addWidget(self.lyric_list, 1)
        buttons = QHBoxLayout()
        self.button('导出', self.export_lyrics, buttons)
        lyric_layout.addLayout(buttons)
        note = QLabel('读取同名 LRC 和内嵌歌词。双击带时间的歌词可跳转。')
        note.setWordWrap(True)
        lyric_layout.addWidget(note)
        self.details.addTab(lyric_widget, '歌词')
        self.info = QLabel('双击歌曲开始播放')
        self.info.setWordWrap(True)
        self.info.setAlignment(Qt.AlignTop)
        info_widget = QWidget()
        info_layout = QVBoxLayout(info_widget)
        info_layout.addWidget(self.info)
        info_layout.addStretch()
        self.details.addTab(info_widget, '音频信息')
        queue_widget = QWidget()
        queue_layout = QVBoxLayout(queue_widget)
        self.queue_list = QListWidget()
        self.queue_list.itemDoubleClicked.connect(self.play_queue_item)
        queue_layout.addWidget(self.queue_list)
        queue_buttons = QHBoxLayout()
        self.button('↑', lambda: self.move_queue(-1), queue_buttons)
        self.button('↓', lambda: self.move_queue(1), queue_buttons)
        self.button('移除', self.remove_queue, queue_buttons)
        queue_layout.addLayout(queue_buttons)
        self.details.addTab(queue_widget, '队列')
        body.addWidget(self.details)
        self.details.hide()
        body.setSizes([190, 690, 280])
        footer = QHBoxLayout()
        self.cover = QLabel('♪')
        self.cover.setFixedSize(64, 64)
        self.cover.setAlignment(Qt.AlignCenter)
        self.cover.setObjectName('cover')
        self.cover.setWordWrap(True)
        self.cover.setTextFormat(Qt.PlainText)
        footer.addWidget(self.cover)
        self.now = QLabel('尚未播放\n导入本地音乐，随时开始')
        self.now.setMinimumWidth(160)
        self.now.setMaximumWidth(290)
        self.now.setWordWrap(True)
        footer.addWidget(self.now)
        self.button('上一首', self.previous, footer)
        self.play_button = self.button('播放', self.toggle, footer)
        self.button('下一首', self.next, footer)
        self.button('停止', self.stop, footer)
        self.shuffle = QCheckBox('随机')
        self.shuffle.setChecked(self.library.settings['shuffle'])
        self.shuffle.toggled.connect(lambda value: self.save_setting('shuffle', value))
        footer.addWidget(self.shuffle)
        self.repeat = QComboBox()
        self.repeat.addItems(['列表循环', '单曲循环', '不循环'])
        self.repeat.setCurrentText(self.library.settings['repeat'])
        self.repeat.currentTextChanged.connect(lambda value: self.save_setting('repeat', value))
        footer.addWidget(self.repeat)
        footer.addStretch()
        self.button('详情 / 歌词', self.toggle_details, footer)
        footer.addWidget(QLabel('音量'))
        self.volume = QSlider(Qt.Horizontal)
        self.volume.setRange(0, 100)
        self.volume.setValue(self.library.settings['volume'])
        self.volume.setMaximumWidth(100)
        self.volume.valueChanged.connect(self.volume_changed)
        self.volume.sliderReleased.connect(self.save_library)
        footer.addWidget(self.volume)
        layout.addLayout(footer)
        timeline = QHBoxLayout()
        self.elapsed = QLabel('0:00')
        self.elapsed.setMinimumWidth(40)
        timeline.addWidget(self.elapsed)
        self.seek = QSlider(Qt.Horizontal)
        self.seek.setRange(0, 10000)
        self.seek.sliderReleased.connect(self.seek_released)
        timeline.addWidget(self.seek, 1)
        self.total = QLabel('0:00')
        timeline.addWidget(self.total)
        layout.addLayout(timeline)
        status_row = QHBoxLayout()
        self.status = QLabel('本地音频播放 · 缺少封面时按歌手匹配在线封面')
        self.status.setWordWrap(True)
        status_row.addWidget(self.status, 1)
        self.cancel_import_button = self.button('取消导入', self.cancel_import, status_row)
        self.cancel_import_button.hide()
        layout.addLayout(status_row)
        self.setStyleSheet('''
            QMainWindow, QDialog { background: #f5f8fd; color: #182b48; }
            QWidget { font-family: "Microsoft YaHei UI", "Segoe UI", sans-serif; font-size: 12px; }
            QLabel#brand { color: #175fca; font-size: 22px; font-weight: 600; }
            QLabel#heading { font-size: 24px; font-weight: 600; }
            QLabel#cover { background: #dcecff; color: #2871d5; border-radius: 10px; font-size: 11px; padding: 3px; }
            QPushButton { background: #e5efff; color: #164f9e; border: 1px solid #c4dafa; border-radius: 6px; padding: 8px 10px; }
            QPushButton:hover { background: #d5e6ff; }
            QPushButton:pressed { background: #bfd8fc; }
            QLineEdit, QComboBox, QSpinBox { background: white; color: #182b48; border: 1px solid #cad8eb; border-radius: 5px; padding: 6px; }
            QTreeWidget, QListWidget { background: white; color: #182b48; border: 1px solid #e0e7f1; border-radius: 7px; alternate-background-color: #f5f8fd; }
            QTreeWidget::item, QListWidget::item { padding: 7px 5px; }
            QTreeWidget::item:selected, QListWidget::item:selected { background: #d4e6ff; color: #174d94; }
            QHeaderView::section { background: #edf3fc; color: #49617f; border: 0; padding: 8px; }
            QSlider::groove:horizontal { background: #d8e3f4; height: 5px; border-radius: 2px; }
            QSlider::sub-page:horizontal { background: #367fe3; border-radius: 2px; }
            QSlider::handle:horizontal { background: #216bd2; width: 12px; margin: -4px 0; border-radius: 6px; }
            QCheckBox { color: #24456d; }
            QTabBar::tab { padding: 8px; color: #234e86; }
            QMenu { background: white; color: #182b48; }
            QMenu::item:selected { background: #d4e6ff; }
        ''')

    def save_library(self):
        try:
            self.library.save()
        except OSError as exc:
            self.status.setText('保存曲库失败：' + str(exc))

    def save_setting(self, key, value):
        self.library.settings[key] = value
        self.save_library()

    def scope(self):
        item = self.nav.currentItem()
        return item.data(Qt.UserRole) if item else 'songs'

    def refresh_navigation(self, selected=None):
        selected = selected or self.scope()
        self.nav.blockSignals(True)
        self.nav.clear()
        for title, identity in [('♫  歌曲', 'songs'), ('▧  专辑', 'albums'), ('♙  艺人', 'artists'), ('♡  收藏', 'favorites'), ('◷  最近播放', 'recent')]:
            item = QListWidgetItem(title)
            item.setData(Qt.UserRole, identity)
            self.nav.addItem(item)
        for identity, playlist in self.library.playlists.items():
            item = QListWidgetItem('☷  ' + playlist['name'])
            item.setData(Qt.UserRole, identity)
            self.nav.addItem(item)
        index = next((i for i in range(self.nav.count()) if self.nav.item(i).data(Qt.UserRole) == selected), 0)
        self.nav.setCurrentRow(index)
        self.nav.blockSignals(False)
        self.nav_changed()

    def nav_changed(self, *args):
        scope = self.scope()
        self.heading.setText(self.library.playlists[scope]['name'] if scope in self.library.playlists else {'songs': '歌曲', 'albums': '专辑', 'artists': '艺人', 'favorites': '收藏', 'recent': '最近播放'}.get(scope, '歌曲'))
        self.group.blockSignals(True)
        self.group.clear()
        self.group.addItem('全部', None)
        key = {'albums': 'album', 'artists': 'artist'}.get(scope)
        if key:
            for value in sorted({getattr(t, key) for t in self.library.tracks.values()}, key=str.casefold):
                self.group.addItem(value, value)
        self.group.setVisible(bool(key))
        self.group.blockSignals(False)
        self.refresh_tracks()

    def visible_ids(self):
        return [self.table.topLevelItem(i).data(0, Qt.UserRole) for i in range(self.table.topLevelItemCount())]

    def selected_ids(self):
        return [item.data(0, Qt.UserRole) for item in self.table.selectedItems()]

    def refresh_tracks(self):
        scope = self.scope()
        tracks = list(self.library.tracks.values())
        if scope in self.library.playlists:
            tracks = [self.library.tracks[t] for t in self.library.playlists[scope]['tracks'] if t in self.library.tracks]
        elif scope == 'favorites':
            tracks = [t for t in tracks if t.favorite]
        elif scope == 'recent':
            tracks = sorted((t for t in tracks if t.last_played), key=lambda t: t.last_played, reverse=True)
        else:
            tracks.sort(key=lambda t: (t.album.casefold(), t.title.casefold()) if scope == 'albums' else (t.artist.casefold(), t.title.casefold()) if scope == 'artists' else t.title.casefold())
        key = {'albums': 'album', 'artists': 'artist'}.get(scope)
        if key and self.group.currentData():
            tracks = [t for t in tracks if getattr(t, key) == self.group.currentData()]
        query = self.search.text().casefold().strip()
        if query:
            tracks = [t for t in tracks if query in ' '.join((t.title, t.artist, t.album)).casefold()]
        self.table.clear()
        reorder = scope in self.library.playlists and not query
        self.table.setDragEnabled(reorder)
        self.table.setAcceptDrops(reorder)
        for track in tracks:
            available = Path(track.path).is_file()
            item = QTreeWidgetItem([('♥ ' if track.favorite else '') + track.title + ('' if available else '  [文件离线]'), track.artist, track.album, clock(track.duration), track.codec.upper() or Path(track.path).suffix[1:].upper()])
            item.setData(0, Qt.UserRole, track.id)
            item.setToolTip(0, track.path)
            # Flat playlist: items accept drops only between rows, never as children.
            item.setFlags(item.flags() & ~Qt.ItemIsDropEnabled)
            self.table.addTopLevelItem(item)
        self.empty.setVisible(not tracks)
        self.empty.setText('将音乐文件或文件夹拖到这里，开始聆听。' if not self.library.tracks else '这里还没有歌曲；可导入音乐、调整搜索或添加到此列表。')

    def persist_order(self):
        scope = self.scope()
        if scope in self.library.playlists and not self.search.text().strip():
            try:
                self.library.playlist_reorder(scope, self.visible_ids())
            except (ValueError, OSError) as exc:
                self.status.setText(str(exc))

    def start_job(self, function, callback, kind='general'):
        identity = uuid.uuid4().hex
        cancel = threading.Event()
        self.jobs[identity] = (cancel, callback, kind)
        self.pool.start(Work(identity, function, cancel, self.bridge))
        return identity

    @Slot(str, object, str)
    def job_result(self, identity, result, error):
        job = self.jobs.pop(identity, None)
        if job:
            if job[0].is_set():
                error = '已取消'
            try:
                job[1](result, error)
            except Exception as exc:
                self.status.setText('操作失败：' + str(exc)[:500])

    @Slot(str, str)
    def job_progress(self, identity, message):
        if identity == self.import_job:
            self.status.setText(message)

    def cancel_job(self, identity):
        if identity in self.jobs:
            self.jobs[identity][0].set()

    def pick_paths(self, folder):
        if folder:
            path = QFileDialog.getExistingDirectory(self, '选择音乐文件夹')
            return [path] if path else []
        paths, _ = QFileDialog.getOpenFileNames(self, '选择音乐', '', '音乐文件 (*.mp3 *.aac *.m4a *.wav *.aif *.aiff *.flac *.alac *.ogg *.oga *.opus *.wma *.wv *.tta *.au *.caf *.ape *.dsf *.dff *.oma *.aa3);;全部文件 (*)')
        return paths

    def pick_import(self, folder):
        paths = self.pick_paths(folder)
        if paths:
            self.import_paths(paths)

    def import_paths(self, paths, replace=False):
        if self.import_job:
            self.status.setText('已有导入任务，请等待或取消后重试。')
            return
        scope = self.scope()
        target = scope if scope in self.library.playlists else None
        self.cancel_import_button.show()
        self.status.setText('正在查找音乐文件…')
        def work(cancel, progress):
            files = discover_audio(paths)
            result, errors = [], []
            for index, path in enumerate(files):
                if cancel.is_set():
                    raise Cancelled()
                progress(f'正在导入 {index + 1}/{len(files)}：{path.name}')
                try:
                    result.append(probe(path))
                except Exception as exc:
                    errors.append(path.name + '：' + str(exc))
            return result, errors
        def done(result, error):
            self.import_job = None
            self.cancel_import_button.hide()
            if error:
                self.status.setText('导入' + error + '；原曲库已保留。')
                return
            tracks, failures = result
            if not tracks:
                self.status.setText('没有找到可读音频；原曲库已保留。' + (' ' + failures[0] if failures else ''))
                return
            if target and target not in self.library.playlists:
                self.status.setText('导入目标播放列表已删除；原曲库已保留。')
                return
            if replace:
                backup = self.library.clear(target)
                self.reset_current()
                self.status.setText('清空前曲库已备份：' + str(backup))
            self.library.add(tracks)
            if target and target in self.library.playlists:
                self.library.playlist_add(target, [track.id for track in tracks])
            self.save_library()
            self.nav_changed()
            message = f'已处理 {len(tracks)} 首歌曲；曲库共 {len(self.library.tracks)} 首。'
            if failures:
                message += f' {len(failures)} 个文件失败：{failures[0][:200]}'
            if replace:
                message += ' 原始文件保留；曲库备份位于数据目录 Backups。'
            self.status.setText(message)
        self.import_job = self.start_job(work, done, 'import')

    def cancel_import(self):
        self.cancel_job(self.import_job)
        self.status.setText('正在取消导入；原曲库保持不变…')

    def show_more(self):
        menu = QMenu(self)
        for label, function in [('清空并重新导入文件…', lambda: self.replace_import(False)), ('清空并重新导入文件夹…', lambda: self.replace_import(True)), ('打开数据文件夹', lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.library.root)))), ('关于 BlueWave', self.about)]:
            menu.addAction(label, function)
        menu.exec(self.cursor().pos())

    def replace_import(self, folder):
        if self.import_job:
            self.status.setText('请先等待或取消当前导入。')
            return
        paths = self.pick_paths(folder)
        if not paths:
            return
        noun = '当前播放列表' if self.scope() in self.library.playlists else '音乐资料库'
        if QMessageBox.question(self, '清空并重新导入', f'将替换{noun}中的记录。原始音乐不会删除，清空前会备份曲库。新音乐全部读取失败或取消导入时保留现有记录。是否继续？') == QMessageBox.Yes:
            self.import_paths(paths, replace=True)

    def create_playlist(self):
        name, ok = QInputDialog.getText(self, '新建播放列表', '名称')
        if ok and name.strip():
            identity = self.library.create_playlist(name)
            self.refresh_navigation(identity)

    def nav_menu(self, position):
        item = self.nav.itemAt(position)
        identity = item.data(Qt.UserRole) if item else None
        if identity not in self.library.playlists:
            return
        menu = QMenu(self)
        menu.addAction('重命名', lambda: self.rename_playlist(identity))
        menu.addAction('删除播放列表', lambda: self.delete_playlist(identity))
        menu.exec(self.nav.mapToGlobal(position))

    def rename_playlist(self, identity):
        name, ok = QInputDialog.getText(self, '重命名', '名称', text=self.library.playlists[identity]['name'])
        if ok and name.strip():
            self.library.rename_playlist(identity, name)
            self.refresh_navigation(identity)

    def delete_playlist(self, identity):
        if QMessageBox.question(self, '删除播放列表', '仅删除此列表，保留音乐文件和资料库歌曲。继续？') == QMessageBox.Yes:
            self.library.delete_playlist(identity)
            self.refresh_navigation('songs')

    def track_menu(self, position):
        ids = self.selected_ids()
        if not ids:
            return
        menu = QMenu(self)
        menu.addAction('播放', lambda: self.play_selected(ids[0]))
        menu.addAction('下一首播放', lambda: self.enqueue(ids, True))
        menu.addAction('添加到队列', lambda: self.enqueue(ids, False))
        menu.addAction('收藏 / 取消收藏', lambda: self.favorite(ids))
        lists = menu.addMenu('添加到播放列表')
        for identity, playlist in self.library.playlists.items():
            lists.addAction(playlist['name'], lambda checked=False, identity=identity: self.add_to_playlist(identity, ids))
        lists.setEnabled(bool(self.library.playlists))
        if self.scope() in self.library.playlists:
            menu.addAction('从当前列表移除', lambda: self.remove_tracks(ids, True))
            menu.addAction('上移', lambda: self.move_playlist(ids, -1))
            menu.addAction('下移', lambda: self.move_playlist(ids, 1))
        menu.addAction('从资料库移除记录', lambda: self.remove_tracks(ids, False))
        menu.addAction('打开所在文件夹', lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(Path(self.library.tracks[ids[0]].path).parent))))
        menu.exec(self.table.mapToGlobal(position))

    def favorite(self, ids):
        for identity in ids:
            if identity in self.library.tracks:
                self.library.tracks[identity].favorite = not self.library.tracks[identity].favorite
        self.save_library()
        self.refresh_tracks()

    def favorite_current(self):
        if self.current:
            self.favorite([self.current.id])

    def add_to_playlist(self, identity, ids):
        self.library.playlist_add(identity, ids)
        self.refresh_tracks()

    def remove_tracks(self, ids, playlist):
        if playlist:
            self.library.playlist_remove(self.scope(), ids)
        elif QMessageBox.question(self, '移除歌曲记录', '仅移除资料库和播放列表记录，保留原始音乐。继续？') == QMessageBox.Yes:
            if self.current and self.current.id in ids:
                self.reset_current()
            self.library.remove(ids)
            self.queue = [identity for identity in self.queue if identity not in ids]
            self.queue_index = self.queue.index(self.current.id) if self.current and self.current.id in self.queue else -1
            self.refresh_queue()
        self.refresh_tracks()

    def move_playlist(self, ids, delta):
        identity = self.scope()
        order = list(self.library.playlists[identity]['tracks'])
        selected = set(ids)
        indices = range(len(order)) if delta < 0 else range(len(order) - 1, -1, -1)
        for index in indices:
            destination = index + delta
            if order[index] in selected and 0 <= destination < len(order) and order[destination] not in selected:
                order[index], order[destination] = order[destination], order[index]
        self.library.playlist_reorder(identity, order)
        self.refresh_tracks()

    def enqueue(self, ids, next_up):
        position = self.queue_index + 1 if next_up else len(self.queue)
        self.queue[position:position] = ids
        self.refresh_queue()

    def refresh_queue(self):
        self.queue_list.clear()
        for index, identity in enumerate(self.queue):
            track = self.library.tracks.get(identity)
            if track:
                item = QListWidgetItem(('▶ ' if index == self.queue_index else '') + track.title)
                item.setData(Qt.UserRole, index)
                self.queue_list.addItem(item)

    def move_queue(self, delta):
        item = self.queue_list.currentItem()
        if item is None:
            return
        index = item.data(Qt.UserRole)
        destination = index + delta
        if 0 <= destination < len(self.queue):
            self.queue[index], self.queue[destination] = self.queue[destination], self.queue[index]
            if self.queue_index == index:
                self.queue_index = destination
            elif self.queue_index == destination:
                self.queue_index = index
            self.refresh_queue()
            self.queue_list.setCurrentRow(destination)

    def remove_queue(self):
        item = self.queue_list.currentItem()
        if item is None:
            return
        index = item.data(Qt.UserRole)
        self.queue.pop(index)
        if index < self.queue_index:
            self.queue_index -= 1
        elif index == self.queue_index:
            self.stop()
            self.queue_index = index - 1
        self.refresh_queue()

    def play_queue_item(self, item):
        self.queue_index = item.data(Qt.UserRole)
        self.play_track(self.queue[self.queue_index])

    def play_item(self, item, column=0):
        self.play_selected(item.data(0, Qt.UserRole))

    def play_selected(self, identity):
        self.queue = self.visible_ids()
        self.queue_index = self.queue.index(identity)
        self.play_track(identity)

    def stop_sessions(self):
        if self.session:
            self.session.cancel()
        if self.fading:
            self.fading.cancel()
        self.session = None
        self.fading = None
        self.paused = False

    def stop(self):
        self.stop_sessions()
        self.cancel_job(self.cover_job)
        self.cover_job = None
        self.play_button.setText('播放')
        self.seek.setValue(0)
        self.elapsed.setText('0:00')
        self.status.setText('已停止')

    def reset_current(self):
        self.stop()
        self.cancel_job(self.cover_job)
        self.current = None
        self.queue = []
        self.queue_index = -1
        self.lyric_identity = None
        self.lyric_text = ''
        self.lyric_lines = []
        self.lyric_list.clear()
        self.lyric_origin.setText('歌词')
        self.now.setText('尚未播放\n导入本地音乐，随时开始')
        self.cover.clear()
        self.cover.setText('♪')
        self.cover.setToolTip('')
        self.info.setText('双击歌曲开始播放')
        self.total.setText('0:00')
        self.refresh_queue()

    def play_track(self, identity, start=0, transition=False):
        track = self.library.tracks.get(identity)
        if track is None:
            return
        if not Path(track.path).is_file():
            self.stop()
            self.status.setText('文件离线，请连接原磁盘或重新导入：' + track.path)
            return
        if transition:
            if self.fading:
                self.fading.cancel()
            self.fading = self.session
            self.fade_started = time.monotonic()
            self.fade_length = min(self.library.settings['crossfade'], max(.1, track.duration / 2))
        else:
            self.stop_sessions()
        changed = self.current is None or self.current.id != track.id
        self.current = track
        self.paused = False
        self.session = AudioSession(track, self.library.settings, start, self.bridge.audio_done.emit)
        if transition:
            self.session.gain = 0
        self.session.start()
        track.last_played = time.time()
        self.save_library()
        self.update_track_display(track)
        self.refresh_queue()
        self.status.setText('正在播放 · 音频仅在本机解码')
        if changed:
            self.cancel_job(self.cover_job)
            self.lyric_identity = None
            self.lyric_text = ''
            self.lyric_lines = []
            self.lyric_list.clear()
            self.cover.clear()
            self.cover.setText(track.title)
        if changed or (start == 0 and not transition):
            self.load_cover(track)
        if self.details.isVisible() and (changed or self.lyric_identity != identity):
            self.load_lyrics()

    def update_track_display(self, track):
        self.now.setText(track.title + '\n' + track.artist)
        self.play_button.setText('播放' if self.paused else '暂停')
        self.total.setText(clock(track.duration))
        self.info.setText(f'{track.title}\n\n艺人：{track.artist}\n专辑：{track.album}\n格式：{track.codec.upper()}\n音源：{track.sample_rate / 1000:g} kHz · {track.channels} 声道\n软件输出：{output_rate(track, self.library.settings["rate"]) / 1000:g} kHz · {self.library.settings["precision"]} bit\n时长：{clock(track.duration)}\n\n{track.metadata_source}\n\n{track.path}\n\nDSD 转 PCM；共享音频输出。实际硬件格式由 Windows 与设备决定。')

    @staticmethod
    def album_key(track):
        artist, album = normalized(track.artist), normalized(track.album)
        if artist in ('', '未知艺人', '未知歌手', 'unknown', 'unknownartist', 'variousartists') or album in ('', '未知专辑', 'unknown', 'unknownalbum'):
            return None
        return artist, album

    def load_cover(self, track):
        if not self.current or self.current.id != track.id:
            return
        self.cancel_job(self.cover_job)
        self.cover.clear()
        self.cover.setText(track.title)
        self.cover.setToolTip('')
        allow_online = bool(self.library.settings['online_covers'])
        tracks = list(self.library.tracks.values())
        resolved = dict(self.album_artworks)
        def work(cancel, progress):
            refreshed = refresh_unknown_track(track)
            if cancel.is_set():
                raise Cancelled()
            local = cover_path(refreshed, self.library.root / 'Covers')
            if cancel.is_set():
                raise Cancelled()
            if local:
                return refreshed, CoverResult(Path(local), ''), True
            own = cached_cover(refreshed.title, refreshed.artist, refreshed.album, self.library.root / 'Covers')
            if own:
                return refreshed, own, True
            if allow_online:
                own = self.online_cover.fetch(refreshed.title, refreshed.artist, refreshed.album, self.library.root / 'Covers', cancel)
                if own:
                    return refreshed, own, True
            key = self.album_key(refreshed)
            if key:
                for sibling in tracks:
                    if cancel.is_set():
                        raise Cancelled()
                    if sibling.id == refreshed.id or self.album_key(sibling) != key:
                        continue
                    candidate = resolved.get(sibling.id)
                    if not candidate:
                        disk = existing_cover_path(sibling, self.library.root / 'Covers')
                        candidate = CoverResult(Path(disk), '') if disk else cached_cover(sibling.title, sibling.artist, sibling.album, self.library.root / 'Covers')
                    if candidate and not QImageReader(str(candidate.path)).read().isNull():
                        return refreshed, candidate, False
            return refreshed, None, False
        def covered(result, error):
            if self.cover_job != job:
                return
            self.cover_job = None
            if not error and self.current and self.current.id == track.id and result:
                refreshed, artwork, own_artwork = result
                if refreshed is not track:
                    refreshed.favorite = self.current.favorite
                    refreshed.last_played = self.current.last_played
                    self.current = refreshed
                    if track.id in self.library.tracks:
                        self.library.tracks[track.id] = refreshed
                        self.save_library()
                        self.refresh_tracks()
                    self.update_track_display(refreshed)
                    self.cover.setText(refreshed.title)
                    self.refresh_queue()
                    if self.details.isVisible():
                        self.load_lyrics()
                if artwork:
                    image = QPixmap(str(artwork.path))
                    if not image.isNull():
                        self.cover.setPixmap(image.scaled(64, 64, Qt.KeepAspectRatio, Qt.SmoothTransformation))
                        if own_artwork:
                            self.album_artworks[track.id] = artwork
                        origin = artwork.provider or ('在线封面' if artwork.source_url else '本地封面')
                        details = [origin]
                        if artwork.artist and artwork.title:
                            details.append(artwork.artist + ' — ' + artwork.title)
                        if artwork.album:
                            details.append(artwork.album)
                        details.extend(value for value in (artwork.source_url, artwork.track_url) if value)
                        self.cover.setToolTip(('' if own_artwork else '同专辑封面 · ') + '\n'.join(details))
        job = self.start_job(work, covered, 'cover')
        self.cover_job = job

    def toggle(self):
        if not self.session:
            if self.current and self.current.id in self.library.tracks:
                self.play_track(self.current.id)
            elif self.table.topLevelItemCount():
                self.play_item(self.table.currentItem() or self.table.topLevelItem(0))
            return
        self.paused = not self.paused
        self.session.pause(self.paused)
        if self.fading:
            self.fading.pause(self.paused)
            if self.paused:
                self.fade_paused_at = time.monotonic()
            else:
                self.fade_started += time.monotonic() - self.fade_paused_at
        self.play_button.setText('播放' if self.paused else '暂停')

    def next_index(self, automatic=False):
        if not self.queue:
            return None
        if automatic and self.repeat.currentText() == '单曲循环':
            return self.queue_index
        if self.shuffle.isChecked() and len(self.queue) > 1:
            return random.choice([i for i in range(len(self.queue)) if i != self.queue_index])
        index = self.queue_index + 1
        if index >= len(self.queue):
            return 0 if self.repeat.currentText() == '列表循环' or not automatic else None
        return index

    def next(self, automatic=False):
        index = self.next_index(automatic)
        if index is None:
            self.stop()
            return
        self.queue_index = index
        self.play_track(self.queue[index])

    def previous(self):
        if not self.queue:
            return
        self.queue_index = (self.queue_index - 1) % len(self.queue)
        self.play_track(self.queue[self.queue_index])

    @Slot(str, str)
    def audio_finished(self, token, error):
        if self.fading and token == self.fading.token:
            self.fading = None
            if self.session:
                self.session.gain = 1
            return
        if not self.session or token != self.session.token:
            return
        if error:
            self.stop()
            self.status.setText('播放失败：' + error[:500])
        else:
            self.next(True)

    def tick(self):
        if not self.session or self.paused:
            return
        position = self.session.position
        if self.current:
            self.elapsed.setText(clock(position))
            if not self.seek.isSliderDown():
                self.seek.setValue(int(min(1, position / max(.001, self.current.duration)) * 10000))
            if self.lyric_lines:
                index = -1
                for i, (stamp, text) in enumerate(self.lyric_lines):
                    if stamp <= position:
                        index = i
                    else:
                        break
                if index >= 0 and self.lyric_list.currentRow() != index:
                    self.lyric_list.setCurrentRow(index)
                    self.lyric_list.scrollToItem(self.lyric_list.item(index), QAbstractItemView.PositionAtCenter)
        if self.fading:
            fraction = min(1, (time.monotonic() - self.fade_started) / max(.01, self.fade_length))
            self.session.gain = fraction
            self.fading.gain = 1 - fraction
            if fraction >= 1:
                self.fading.cancel()
                self.fading = None
                self.session.gain = 1
        elif self.current and self.library.settings['crossfade'] and self.repeat.currentText() != '单曲循环':
            remaining = self.current.duration - position
            if 0 < remaining <= self.library.settings['crossfade'] and self.current.duration > 2 * self.library.settings['crossfade']:
                index = self.next_index(True)
                if index is not None and index != self.queue_index:
                    self.queue_index = index
                    self.play_track(self.queue[index], transition=True)

    def seek_to(self, seconds):
        if self.current:
            paused = self.paused
            self.play_track(self.current.id, max(0, min(seconds, max(0, self.current.duration - .05))))
            if paused:
                self.toggle()

    def seek_released(self):
        if self.current:
            self.seek_to(self.current.duration * self.seek.value() / 10000)

    def volume_changed(self, value):
        self.library.settings['volume'] = value
        for session in (self.session, self.fading):
            if session:
                session.volume = value / 100

    def settings(self):
        dialog = Settings(self.library.settings, self)
        if dialog.exec() == QDialog.Accepted:
            self.library.settings.update(dialog.values())
            self.save_library()
            if self.current and self.session:
                self.load_cover(self.current)
            elif not self.library.settings['online_covers']:
                self.cancel_job(self.cover_job)
                self.cover_job = None

    def toggle_details(self):
        self.details.setVisible(not self.details.isVisible())
        if self.details.isVisible() and self.current and self.lyric_identity != self.current.id:
            self.load_lyrics()

    def show_lyrics(self, text, origin):
        self.lyric_text = text
        self.lyric_lines = parse_lrc(text)
        self.lyric_origin.setText(origin)
        self.lyric_list.clear()
        self.lyric_list.addItems([line for stamp, line in self.lyric_lines] if self.lyric_lines else text.splitlines())

    def load_lyrics(self):
        track = self.current
        if not track:
            return
        self.lyric_identity = track.id
        try:
            text, origin = read_lyrics(track)
        except OSError as exc:
            self.show_lyrics('', '本地歌词无法读取：' + str(exc))
            return
        self.show_lyrics(text, origin if text else '没有本地歌词；可添加同名 LRC 或使用带内嵌歌词的音频。')

    def seek_lyric(self, item):
        row = self.lyric_list.row(item)
        if self.lyric_lines and 0 <= row < len(self.lyric_lines):
            self.seek_to(self.lyric_lines[row][0])

    def export_lyrics(self):
        if not self.lyric_text or not self.current:
            self.status.setText('还没有可导出的歌词。')
            return
        name = ''.join(c for c in self.current.title if c not in '<>:"/\\|?*') or 'lyrics'
        path, _ = QFileDialog.getSaveFileName(self, '导出歌词', name + '.lrc', '歌词 (*.lrc);;文本 (*.txt)')
        if path:
            try:
                Path(path).write_text(self.lyric_text, encoding='utf-8')
                self.status.setText('歌词已导出：' + path)
            except OSError as exc:
                self.status.setText(str(exc))

    def about(self):
        QMessageBox.about(self, '关于 BlueWave', 'BlueWave 蓝调音乐 · Windows 1.0.4\n\n本地多格式播放器，MIT 开源。Qt/PySide6 界面，FFmpeg 解码，PortAudio 共享音频输出，支持同名 LRC 与内嵌歌词。\n\n不支持加密音频、原生 DSD、DoP、独占输出或位完美保证。未签名 Windows 包可能触发 SmartScreen。详见包内许可证与 Windows README。')

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        paths = [url.toLocalFile() for url in event.mimeData().urls() if url.isLocalFile()]
        if paths:
            self.import_paths(paths)
            event.acceptProposedAction()

    def closeEvent(self, event):
        self.stop_sessions()
        for cancel, callback, kind in self.jobs.values():
            cancel.set()
        self.save_library()
        event.accept()


def smoke_test(app):
    """CI exercises real float32 decoding and a Qt window without an audio device."""
    import struct
    from core import decode_bytes
    with tempfile.TemporaryDirectory(prefix='BlueWave-smoke-') as folder:
        root = Path(folder)
        path = root / '蓝调 test.wav'
        with wave.open(str(path), 'wb') as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(16000)
            out.writeframes(struct.pack('<h', 1000) * 1600)
        track = probe(path)
        assert abs(track.duration - .1) < .01
        assert len(decode_bytes(track, rate=48000)) == 4800 * 8
        library = Library(root / 'profile')
        library.add([track])
        library.save()
        window = Window(library)
        window.show()
        app.processEvents()
        assert window.table.topLevelItemCount() == 1
        assert window.heading.text() == '歌曲'
        window.close()
        app.processEvents()
        if sys.stdout is not None:
            print('BlueWave smoke OK: FFprobe, real float32 decode and Qt window. No audio device required.', flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--smoke-test', action='store_true')
    args = parser.parse_args()
    if args.smoke_test:
        os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
    app = QApplication(sys.argv)
    app.setApplicationName('BlueWave')
    app.setOrganizationName('BlueWave')
    app.setStyle('Fusion')
    if args.smoke_test:
        try:
            return smoke_test(app)
        except Exception as exc:
            if sys.stderr is not None:
                print('BlueWave smoke failed: ' + str(exc), file=sys.stderr, flush=True)
            return 1
    try:
        window = Window()
    except Exception as exc:
        QMessageBox.critical(None, 'BlueWave 无法打开曲库', str(exc) + '\n\n请备份并修复此文件后重试；应用没有覆盖原曲库。')
        return 1
    window.show()
    return app.exec()


if __name__ == '__main__':
    sys.exit(main())
