#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor Downloads
archive=Downloads/ffmpeg-9.0.2.tar.xz
if [ ! -f "$archive" ] && [ -f third-party/ffmpeg/ffmpeg-9.0.2.tar.xz ]; then cp third-party/ffmpeg/ffmpeg-9.0.2.tar.xz "$archive"; fi
if [ ! -f "$archive" ]; then
  curl -fL --retry 2 -o "$archive" https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
fi
tar -xf "$archive" -C Downloads
cd Downloads/ffmpeg-9.0.2
./configure --prefix="$PWD/../../Vendor/local" --cc=clang --arch=arm64 --target-os=darwin \
  --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
  --disable-autodetect --disable-network --disable-doc --disable-debug --disable-asm --disable-everything \
  --enable-ffmpeg --enable-ffprobe --enable-avfilter --enable-swresample --enable-zlib \
  --enable-protocol=file,pipe --enable-filter=aresample,aformat,anull,volume,scale,format,loudnorm,alimiter \
  --enable-decoder=aac,aac_fixed,aac_latm,ac3,ac3_fixed,eac3,alac,als,ape,atrac1,atrac3,atrac3al,atrac3plus,atrac3plusal,atrac9,flac,mp1,mp1float,mp2,mp2float,mp3,mp3float,mp3adu,mp3adufloat,opus,vorbis,wmav1,wmav2,wmapro,wmalossless,wmavoice,wavpack,tta,tak,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,dst,dca,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_alaw,pcm_mulaw,adpcm_ima_wav,mjpeg,png \
  --enable-demuxer=aac,ac3,eac3,aiff,ape,asf,au,caf,dsf,iff,dts,flac,mov,mp3,ogg,oma,wav,wv,tta,tak,matroska \
  --enable-parser=aac,aac_latm,ac3,flac,mpegaudio,opus,vorbis,dca,png,mjpeg \
  --enable-encoder=pcm_f32le,pcm_s16le,png,flac,alac \
  --enable-muxer=pcm_f32le,wav,image2,image2pipe,flac,ipod
make -j8
cp ffmpeg ffprobe ../../Vendor/
cp config.h ../../Vendor/ffmpeg-config.h
cp ffbuild/config.mak ../../Vendor/ffmpeg-config.mak
cp COPYING.LGPLv2.1 LICENSE.md ../../Vendor/
../../Vendor/ffmpeg -version > ../../Vendor/BUILD.txt 2>&1
shasum -a 256 ../../Vendor/ffmpeg ../../Vendor/ffprobe ../../Downloads/ffmpeg-9.0.2.tar.xz > ../../Vendor/SHA256SUMS
