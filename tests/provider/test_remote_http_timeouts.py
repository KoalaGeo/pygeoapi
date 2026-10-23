# =================================================================
#
# Copyright (c) 2026 pygeoapi development team
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# =================================================================

# Outbound HTTP requests to remote data sources must always carry a
# timeout, so that an unresponsive upstream cannot hold a worker forever.

from unittest import mock

import pytest
import requests

from pygeoapi.provider.base import ProviderGenericError
from pygeoapi.provider.mvt_elastic import MVTElasticProvider
from pygeoapi.provider.mvt_proxy import MVTProxyProvider
from pygeoapi.provider.mvt_tippecanoe import MVTTippecanoeProvider
from pygeoapi.provider.wms_facade import WMSFacadeProvider
from pygeoapi.pubsub.http import HTTPPubSubClient
from pygeoapi.util import HTTP_TIMEOUT


def _tile_def(name, data):
    return {
        'name': name,
        'type': 'tile',
        'data': data,
        'options': {
            'zoom': {'min': 0, 'max': 15},
            'schemes': ['WebMercatorQuad']
        },
        'format': {
            'name': 'pbf',
            'mimetype': 'application/vnd.mapbox-vector-tile'
        }
    }


MVT_PROVIDERS = [
    (MVTProxyProvider,
     _tile_def('MVT-proxy', 'http://tiles.example.org/layer/{z}/{x}/{y}')),
    (MVTElasticProvider,
     _tile_def('MVT-elastic',
               'http://es.example.org:9200/layer/_mvt/geom/{z}/{x}/{y}')),
]


@pytest.mark.parametrize('cls,provider_def', MVT_PROVIDERS)
def test_mvt_remote_tile_single_request_with_timeout(cls, provider_def):
    p = cls(provider_def)

    response = mock.Mock(status_code=200, content=b'tile')
    with mock.patch.object(requests.Session, 'get',
                           return_value=response) as get:
        assert p.get_tiles(layer=p.get_layer(), tileset='WebMercatorQuad',
                           z=1, y=0, x=0, format_='pbf') == b'tile'

    # exactly one upstream request per tile (no warm-up request)
    assert get.call_count == 1
    assert get.call_args.kwargs['timeout'] == HTTP_TIMEOUT


@pytest.mark.parametrize('cls,provider_def', MVT_PROVIDERS)
def test_mvt_remote_tile_timeout_is_provider_error(cls, provider_def):
    p = cls(provider_def)

    with mock.patch.object(requests.Session, 'get',
                           side_effect=requests.exceptions.Timeout):
        with pytest.raises(ProviderGenericError):
            p.get_tiles(layer=p.get_layer(), tileset='WebMercatorQuad',
                        z=1, y=0, x=0, format_='pbf')


def test_mvt_tippecanoe_url_single_request_with_timeout():
    provider_def = _tile_def(
        'MVT-tippecanoe', 'http://tiles.example.org/layer/{z}/{x}/{y}.pbf')

    with mock.patch.object(requests, 'head',
                           return_value=mock.Mock(status_code=200)) as head:
        p = MVTTippecanoeProvider(provider_def)
        p.get_tiles_service(baseurl='http://localhost',
                            servicepath='/tiles')
    for call in head.call_args_list:
        assert call.kwargs['timeout'] == HTTP_TIMEOUT

    response = mock.Mock(status_code=200, content=b'tile')
    with mock.patch.object(requests.Session, 'get',
                           return_value=response) as get:
        assert p.get_tiles(layer=p.get_layer(), tileset='WebMercatorQuad',
                           z=1, y=0, x=0, format_='pbf') == b'tile'

    assert get.call_count == 1
    assert get.call_args.kwargs['timeout'] == HTTP_TIMEOUT

    with mock.patch.object(requests.Session, 'get',
                           side_effect=requests.exceptions.Timeout):
        with pytest.raises(ProviderGenericError):
            p.get_tiles(layer=p.get_layer(), tileset='WebMercatorQuad',
                        z=1, y=0, x=0, format_='pbf')


def test_wms_facade_timeout():
    p = WMSFacadeProvider({
        'name': 'WMSFacade',
        'type': 'map',
        'data': 'http://wms.example.org/wms',
        'options': {'layer': 'test', 'style': 'default'},
        'format': {'name': 'png', 'mimetype': 'image/png'}
    })

    response = mock.Mock(content=b'png')
    with mock.patch.object(requests, 'get', return_value=response) as get:
        assert p.query(bbox=[-180, -90, 180, 90]) == b'png'

    assert get.call_args.kwargs['timeout'] == HTTP_TIMEOUT


def test_http_pubsub_timeout():
    client = HTTPPubSubClient({
        'name': 'HTTP',
        'broker': {'url': 'http://broker.example.org/notify'}
    })

    with mock.patch.object(requests, 'post') as post:
        client.pub('collections/obs', '{}')

    assert post.call_args.kwargs['timeout'] == HTTP_TIMEOUT
