//
//  Errors.swift
//  TunnelKit
//
//  Created by Davide De Rosa on 5/19/19.
//  Copyright (c) 2021 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of TunnelKit.
//
//  TunnelKit is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  TunnelKit is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with TunnelKit.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import CTunnelKitCore

extension Error {
    public func isTunnelKitError() -> Bool {
        let te = self as NSError
        return te.domain == TunnelKitErrorDomain
    }
    
    public func tunnelKitErrorCode() -> TunnelKitErrorCode? {
        let te = self as NSError
        guard te.domain == TunnelKitErrorDomain else {
            return nil
        }
        return TunnelKitErrorCode(rawValue: te.code)
    }
}
