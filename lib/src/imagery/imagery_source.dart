import '../geometry/tile.dart';

/// A layer of background imagery to trace over.
///
/// Shaped like an entry in the editor layer index, the list of imagery that
/// OpenStreetMap editors share and that iD reads its choices from, so that
/// the index can be read straight into these later.
class ImagerySource {
  /// The index's identifier for the layer.
  final String id;

  /// What the layer is called.
  final String name;

  /// Where a tile is, with `{zoom}`, `{x}` and `{y}` to fill in.
  final String url;

  /// The closest zoom the layer has tiles for. Closer than this the tiles of
  /// this zoom are stretched.
  final int maximumZoom;

  /// The credit the layer's licence asks for.
  final String attribution;

  /// Creates a source.
  const ImagerySource({
    required this.id,
    required this.name,
    required this.url,
    required this.maximumZoom,
    required this.attribution,
  });

  /// Where [tile] is.
  Uri tileUri(TileId tile) => Uri.parse(
    url
        .replaceAll('{zoom}', '${tile.zoom}')
        .replaceAll('{x}', '${tile.x}')
        .replaceAll('{y}', '${tile.y}'),
  );
}

/// Aerial imagery of all of New Zealand from Toitū Te Whenua LINZ.
///
/// The entry iD uses, copied from the editor layer index including the key,
/// which LINZ issued for OpenStreetMap editors to share. LINZ has given
/// OpenStreetMap written permission to trace it.
const linzAerial = ImagerySource(
  id: 'LINZ_NZ_Aerial_Imagery',
  name: 'LINZ NZ Aerial Imagery',
  url:
      'https://basemaps.linz.govt.nz/v1/tiles/aerial/WebMercatorQuad/'
      '{zoom}/{x}/{y}.webp?api=d01egend5f8dv4zcbfj6z2t7rs3',
  maximumZoom: 21,
  attribution: 'Sourced from LINZ CC-BY 4.0',
);
