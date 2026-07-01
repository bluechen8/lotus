/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#ifndef STATS_H_
#define STATS_H_

#include <cstdint>
#include <vector>
#include <cassert>
#include <string>
#include <functional>
#include <memory>
#include <sstream>
#include <iostream>

#define TRACEF(args...) // printf(args)
#define TRACEC(args...) // std::cout << std::hex << args << std::dec

#include "hw.h"

using std::vector;
using std::tuple;
using std::string;
typedef enum: uint8_t {
    SIPMux      = 1 << 0, // 0
    SIPSplitter = 1 << 1, // 1
    SIPTable    = 1 << 2, // 2 Child can be Control, Status, Counter
    SIPControl  = 1 << 3, // 3
    SIPStatus   = 1 << 4, // 4
    SIPCounter  = 1 << 5, // 5
    SIPFilterNode = 1 << 6 // 6
} SIPType_t;

const uint8_t SIPEndpointMask = SIPControl | SIPStatus | SIPCounter;


class SIPNode_t;

class SIPNode_t {
public:

    struct Members_t {
        const std::string name;
        const SIPType_t type;
        const int numBytes;
        int id;
        SIPNode_t* parent;
        std::vector<SIPNode_t*> children;
        std::vector<uint64_t> history;
    } m;

    SIPNode_t(const std::string name, const SIPType_t type, const int numBytes)
        : m({.name =  name, .type = type, .numBytes = numBytes, .id = -1, .parent = nullptr, .children = {}}) {
        assert(this->m.numBytes <= 8);
    }

    SIPNode_t(SIPNode_t&& other) noexcept
        : m(std::move(other.m)) {
    }


    SIPNode_t(const SIPNode_t& other)
    : m(other.m) {}

    SIPNode_t& operator=(const SIPNode_t&) = delete;
    SIPNode_t& operator=(SIPNode_t&&) = delete;


    SIPNode_t* addChild(SIPNode_t* child) {
        assert(child->m.parent == nullptr);
        child->m.parent = this;
        child->m.id     = this->m.children.size();
        this->m.children.push_back(child);
        return this;
    }

    template<typename T>
    T readNode(hw::Device* d) {
        TRACEF("readNode on '%s'\n", this->getFullName().c_str());
        if (this->m.type == SIPType_t::SIPFilterNode) {
            return this->consumeFilter()->readNode<T>(d);
        }
        assert((this->m.type == SIPType_t::SIPStatus)
               || (this->m.type == SIPType_t::SIPCounter));
        assert(sizeof(T) >= this->m.numBytes);

        T ret = d->read_sip_reg<T>(this->getNodeAddr());

        TRACEF("readNode on '%s' => ret='", this->getFullName().c_str());
        TRACEC(ret << "'" << std::endl);

        return ret;
    }

    template<typename T>
    void writeNode(hw::Device* d, T data) {
        TRACEF("writeNode on '%s' <= data='", this->getFullName().c_str());
        TRACEC(data << "'" << std::endl);
        if (this->m.type == SIPType_t::SIPFilterNode) {
            this->consumeFilter()->writeNode<T>(d, data);
            return;
        }

        assert(this->m.type == SIPType_t::SIPControl);
        assert(sizeof(T) == this->m.numBytes);

        d->write_sip_reg<T>(this->getNodeAddr(), data);
    }

    template<typename T>
    void writeNodeCached(hw::Device* d, T data) {
        TRACEF("writeNode on '%s' <= data='", this->getFullName().c_str());
        TRACEC(data << "'" << std::endl);
        if (this->m.type == SIPType_t::SIPFilterNode) {
            this->consumeFilter()->writeNodeCached<T>(d, data);
            return;
        }

        assert(this->m.type == SIPType_t::SIPControl);
        assert(sizeof(T) == this->m.numBytes);

        d->write_sip_reg_cached<T>(this->getNodeAddr(), data);
    }

    std::vector<uint8_t> getNodeAddr() {
        assert(this->m.type != SIPType_t::SIPSplitter);
        std::vector<uint8_t> addrs;
        if (this->m.parent != nullptr)
            addrs = this->m.parent->getNodeAddr();
        auto& id = this->m.id;
        if (id >= 0) {
            addrs.push_back(id);
        }
        return addrs;
    }

    void dump(hw::Device* d, vector<tuple<string, string>>& enteries, uint32_t chip_id)  {
        vector<tuple<string, string>> entries;
        auto get_list = [](auto& hist) -> string {
            std::ostringstream oss;
            oss << "[";
            auto last_i = hist.size()-1;
            for (size_t i = 0; i < hist.size(); i++) {
                auto& h = hist[i];
                oss << h;
                if (i != last_i) oss << ", ";
            }
            oss << "]";
            return oss.str();
        };

        switch (this->m.type) {
            case SIPType_t::SIPMux:
            case SIPType_t::SIPSplitter:
            case SIPType_t::SIPTable:
            case SIPType_t::SIPFilterNode: {
                for (auto& child : this->m.children) child->dump(d, enteries, chip_id);
            }
            break;
            case SIPType_t::SIPCounter:
            case SIPType_t::SIPStatus: {
                std::string name = std::string{"chip"} + std::to_string(chip_id) + "." + this->getFullName();
                enteries.push_back({name, get_list(this->m.history)});
            }
            break;
            case SIPType_t::SIPControl: assert(false && "Can't capture a control node");
        }
    }
    void capture(hw::Device* d) {
        assert(this->m.numBytes <= 8);

        switch (this->m.type) {
            case SIPType_t::SIPMux:
            case SIPType_t::SIPSplitter:
            case SIPType_t::SIPTable:
            case SIPType_t::SIPFilterNode: {
                for (auto& child : this->m.children) child->capture(d);
            }
            break;
            case SIPType_t::SIPCounter:
            case SIPType_t::SIPStatus: {
                uint64_t val = readNode<uint64_t>(d);
                this->m.history.push_back(val);
            }
            break;
            case SIPType_t::SIPControl: assert(false && "Can't capture a control node");
        }
    }

    std::unique_ptr<SIPNode_t> filterNodes(const std::function<bool(SIPNode_t*)>& filt, std::unique_ptr<SIPNode_t> v = nullptr) {
        if (!v) {
            v = newFilterNode();
        }

        if (filt(this)) {
            v->m.children.push_back(this);
        }

        for (auto& n : this->m.children)
            v = n->filterNodes(filt, std::move(v));

        return v;
    }

    std::unique_ptr<SIPNode_t> filterByType(const SIPType_t & type) {
        return this->filterNodes([type](SIPNode_t * n) -> bool {
                                     return (n->m.type & type) != 0;
                                 });
    }

    std::unique_ptr<SIPNode_t> filterByName(const std::string& name) {
        auto ret =  this->filterNodes([name](SIPNode_t * n) -> bool {
                                          return (n->m.name == name);
                                     });
        //printf("filterByName(name=%s) = [", name.c_str());
        //for (auto& c : ret->m.children) {
        //    printf("'%s', ", c->m.name.c_str());
        //}
        //printf("]\n");
        return ret;
    }

    std::string getFullName(std::string fn = "") {
        if (this->m.parent != nullptr)
            fn = this->m.parent->getFullName(std::move(fn));

        if (fn.size() > 0) {
            fn += ".";
        }
        fn += this->m.name;

        return fn;
    }


    static std::unique_ptr<SIPNode_t> newFilterNode() {
        return std::make_unique<SIPNode_t>("Filter", SIPType_t::SIPFilterNode, -1);
    }

    static std::string createIdentifier(const std::string base, uint32_t n) {
        std::ostringstream oss;
        oss << base << n;
        auto s = oss.str();

        return s;
    }

    static SIPNode_t* createTable(std::string tableName, SIPType_t type, const int bytes, const std::vector<std::string>& names) {
        SIPNode_t * tableRoot = new SIPNode_t(tableName, SIPType_t::SIPTable, -1);

        for (auto& name : names) {
            tableRoot->addChild(new SIPNode_t(name, type, bytes));
        }
        return tableRoot;
    }
    static SIPNode_t* createMux(std::string muxName, const std::vector<SIPNode_t*>& children) {
        SIPNode_t * muxRoot = new SIPNode_t(muxName, SIPType_t::SIPMux, -1);

        for (auto& child : children) {
            muxRoot->addChild(child);
        }
        return muxRoot;
    }

    SIPNode_t* consumeFilter() {
        assert(this->m.type == SIPType_t::SIPFilterNode);
        assert(this->m.children.size() == 1);
        return this->m.children[0];
    }

};



#endif // STATS_H_
